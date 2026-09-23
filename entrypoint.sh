#!/bin/sh
# Entrypoint for the Pearl (PRL, pearlhash) SaladCloud NVIDIA image.
#
# Tries each miner in $MINERS in order. A miner "works" once it logs an
# accepted share; if it exits, or produces no accepted share within
# $NO_SHARE_TIMEOUT seconds, it is killed and the next miner is tried.

set -u

if [ "${WALLET:-REPLACE_WITH_YOUR_WALLET}" = "REPLACE_WITH_YOUR_WALLET" ]; then
  echo "ERROR: set the WALLET environment variable in your SaladCloud container group." >&2
  exit 1
fi
case "$WALLET" in
  prl1*) ;;
  *) echo "WARNING: Pearl mainnet addresses start with 'prl1p'. WALLET='$WALLET' looks wrong - pools will reject it." >&2 ;;
esac

WORKER_NAME="${SALAD_MACHINE_ID:-${WORKER:-salad01}}"
# Salad machine ids are long UUIDs; pools usually cap worker names, so trim.
WORKER_NAME="$(echo "$WORKER_NAME" | tr -cd 'A-Za-z0-9_-' | cut -c1-24)"
USER_ARG="$WALLET.$WORKER_NAME"

MINERS="${MINERS:-krig srb bz wildrig}"
NO_SHARE_TIMEOUT="${NO_SHARE_TIMEOUT:-300}"
LOG=/tmp/miner.log

echo "=== GPU readiness check (nvidia-smi) ==="
echo "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-<unset>}  NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-<unset>}"
GPU_NAME=""
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1; then
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  else
    echo "nvidia-smi failed - the host driver was not injected. Is this an NVIDIA GPU class?"
  fi
else
  echo "nvidia-smi not found - the container toolkit did not inject the driver. Is this an NVIDIA GPU class?"
fi
echo "=== GPU: ${GPU_NAME:-unknown}  miner order: $MINERS ==="

echo "=== OpenCL platforms (clinfo) - only matters for WildRig ==="
clinfo -l 2>&1 | head -20 || true

# Pool region auto-select. Salad nodes are spread worldwide and Pearl shares
# are heavy STARK proofs, so a far-away pool costs stale rejects. If the pool
# is HeroMiners, time a TCP connect to each region and use the fastest.
# Disable with POOL_AUTO=0 or by setting a non-HeroMiners POOL.
if [ "${POOL_AUTO:-1}" = "1" ] && echo "$POOL" | grep -qE 'pearl\.herominers\.com'; then
  scheme="$(echo "$POOL" | sed -nE 's#^([a-z+]+://).*#\1#p')"
  port="$(echo "$POOL" | sed -nE 's#.*:([0-9]+)$#\1#p')"
  port="${port:-1200}"
  POOL_REGIONS="${POOL_REGIONS:-ca us us2 us3 de es fi fr ru tr hk sg kr au br}"
  echo "=== Probing HeroMiners Pearl regions on port $port ==="
  best=""; best_ms=999999
  for r in $POOL_REGIONS; do
    h="$r.pearl.herominers.com"
    t="$(curl -s -o /dev/null --max-time 3 -w '%{time_connect}' "telnet://$h:$port" 2>/dev/null </dev/null)"
    ms="$(echo "${t:-0}" | awk '{ printf "%d", $1 * 1000 }')"
    if [ "$ms" -gt 0 ]; then
      echo "  $r: ${ms} ms"
      if [ "$ms" -lt "$best_ms" ]; then best="$r"; best_ms="$ms"; fi
    else
      echo "  $r: unreachable"
    fi
  done
  if [ -n "$best" ]; then
    POOL="${scheme:-stratum+tcp://}$best.pearl.herominers.com:$port"
    echo "=== Using nearest region: $best (${best_ms} ms) -> $POOL ==="
  else
    echo "=== No region reachable by probe; keeping $POOL ==="
  fi
fi

# Pool URL without the stratum+tcp:// scheme, for miners that want host:port.
POOL_HOSTPORT="$(echo "$POOL" | sed -E 's#^[a-z+]+://##')"

# Print the miner command for a given name. Every miner spells the algorithm
# differently, so it is hardcoded per miner rather than taken from an env var:
#   krig    --coin pearl        (aliases: prl, pearlhash)
#   srb     --algorithm pearlhash
#   bz      -a pearl
#   wildrig --algo pearlhash
miner_cmd() {
  case "$1" in
    krig)
      echo /opt/krig/krig-miner --coin pearl -o "$POOL_HOSTPORT" -u "$USER_ARG" -p x \
        --no-tui --no-rocm ${KRIG_EXTRA_ARGS:-}
      ;;
    srb)
      echo /opt/srb/SRBMiner-MULTI --algorithm pearlhash --pool "$POOL_HOSTPORT" \
        --wallet "$USER_ARG" --password x --disable-cpu \
        ${SRB_EXTRA_ARGS:-}
      ;;
    bz)
      echo /opt/bz/bzminer -a pearl -p "$POOL" -w "$WALLET" --worker "$WORKER_NAME" \
        --pass x --cpu 0 ${BZ_EXTRA_ARGS:-}
      ;;
    wildrig)
      echo /opt/wildrig/wildrig-multi --algo pearlhash --url "$POOL" --user "$USER_ARG" \
        --pass x --opencl-platforms nvidia --no-adl --no-igcl --no-sysfs \
        ${WILDRIG_EXTRA_ARGS:-}
      ;;
    *)
      echo "echo unknown miner '$1'; false"
      ;;
  esac
}

# Accepted-share detector. Each miner words it differently; WildRig's stats
# table also prints "Accepted: -" which must NOT count.
has_accepted() {
  grep -iE 'accepted' "$LOG" 2>/dev/null | grep -vE 'Accepted: ' | grep -qiE 'accept'
}

run_miner() {
  name="$1"
  if [ ! -d "/opt/$name" ]; then
    echo "=== [$name] not installed in this image - skipping ==="
    return 1
  fi
  : > "$LOG"
  echo "=== [$name] starting: $(miner_cmd "$name") ==="
  cd "/opt/$name"
  sh -c "$(miner_cmd "$name")" 2>&1 | tee "$LOG" &
  pipeline_pid=$!
  start=$(date +%s)
  confirmed=0
  while :; do
    sleep 10
    if ! kill -0 "$pipeline_pid" 2>/dev/null; then
      echo "=== [$name] exited ==="
      return 1
    fi
    if [ "$confirmed" -eq 0 ] && has_accepted; then
      confirmed=1
      echo "=== [$name] ACCEPTED SHARE - this miner works on this node ==="
      # Stop tailing the log into a growing file; from here the miner just runs.
      wait "$pipeline_pid"
      echo "=== [$name] exited after running successfully ==="
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$confirmed" -eq 0 ] && [ "$elapsed" -ge "$NO_SHARE_TIMEOUT" ]; then
      echo "=== [$name] no accepted share after ${elapsed}s - killing and trying next miner ==="
      pkill -f "/opt/$name/" 2>/dev/null
      sleep 3
      pkill -9 -f "/opt/$name/" 2>/dev/null
      return 1
    fi
  done
}

while :; do
  for m in $MINERS; do
    if run_miner "$m"; then
      # It worked then died (pool drop / node hiccup): stick with this miner.
      MINERS="$m"
      break
    fi
  done
  echo "=== restarting in 15s ==="
  sleep 15
done
