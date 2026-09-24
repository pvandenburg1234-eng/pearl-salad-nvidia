#!/bin/sh
# Entrypoint for the Pearl (PRL, pearlhash) SaladCloud NVIDIA image.
#
# Tries each miner in $MINERS in order. A miner "works" once it logs an
# accepted share; if it exits, or produces no accepted share within
# $NO_SHARE_TIMEOUT seconds, it is killed and the next miner is tried.

set -u

# This script is PID 1. Without a trap, PID 1 ignores SIGTERM and a Salad
# stop/reallocation waits out the grace period and SIGKILLs everything.
cleanup() {
  echo "=== SIGTERM received - stopping miner ==="
  pkill -TERM -f '/opt/' 2>/dev/null
  sleep 2
  pkill -KILL -f '/opt/' 2>/dev/null
  exit 0
}
trap cleanup TERM INT

# Interruptible sleep: a trap can't run while a foreground `sleep` is active,
# so background it and wait (wait IS interruptible).
isleep() { sleep "$1" & wait $! 2>/dev/null; }

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
# Pearl shares are STARK proofs; on a weak card at a not-yet-adjusted pool
# difficulty the first one can take several minutes, so give it 10.
NO_SHARE_TIMEOUT="${NO_SHARE_TIMEOUT:-600}"
LOG=/tmp/miner.log

echo "=== pearl-salad-nvidia image version: ${IMAGE_VERSION:-unknown} ==="
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
# is HeroMiners or Kryptex, time a TCP connect to each of that pool's regions
# and use the fastest. Disable with POOL_AUTO=0 or by using another pool.
#
# probe_regions LABEL SUFFIX DEFAULT_PORT REGION...
#   Probes "<region><suffix>:<port>" for each region and rewrites POOL to the
#   fastest one, keeping the scheme and port from the original POOL.
probe_regions() {
  label="$1"; suffix="$2"; defport="$3"; shift 3
  scheme="$(echo "$POOL" | sed -nE 's#^([a-z+]+://).*#\1#p')"
  port="$(echo "$POOL" | sed -nE 's#.*:([0-9]+)$#\1#p')"
  port="${port:-$defport}"
  echo "=== Probing $label regions on port $port ==="
  best=""; best_ms=999999
  for r in "$@"; do
    h="$r$suffix"
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
    POOL="${scheme:-stratum+tcp://}$best$suffix:$port"
    echo "=== Using nearest region: $best (${best_ms} ms) -> $POOL ==="
  else
    echo "=== No region reachable by probe; keeping $POOL ==="
  fi
}

if [ "${POOL_AUTO:-1}" = "1" ]; then
  if echo "$POOL" | grep -qE 'pearl\.herominers\.com'; then
    # shellcheck disable=SC2086
    probe_regions "HeroMiners Pearl" ".pearl.herominers.com" 1200 \
      ${POOL_REGIONS:-ca us us2 us3 de es fi fr ru tr hk sg kr au br}
  elif echo "$POOL" | grep -qE 'prl(-[a-z]+)?\.kryptex\.network'; then
    # shellcheck disable=SC2086
    probe_regions "Kryptex Pearl" ".kryptex.network" 7048 \
      ${POOL_REGIONS:-prl prl-us prl-eu prl-br prl-sg prl-hk prl-ru prl-ae}
  fi
fi

# krig-miner is Kryptex's miner and refuses every other pool ("is not the
# official Kryptex PRL pool"), retrying forever instead of exiting. Only run
# it when POOL is Kryptex; otherwise skip it so the other miners start at once.
case "$POOL" in
  *kryptex.network*) KRIG_OK=1 ;;
  *) KRIG_OK=0 ;;
esac

# Pool URL without the scheme, for miners that want host:port, and whether
# the scheme asked for TLS (stratum+ssl:// or stratum+tls://).
POOL_HOSTPORT="$(echo "$POOL" | sed -E 's#^[a-z+]+://##')"
case "$POOL" in
  stratum+ssl://*|stratum+tls://*|ssl://*|tls://*) POOL_TLS=1 ;;
  *) POOL_TLS=0 ;;
esac
# krig-miner ONLY speaks TLS ("plain TCP is not supported"). Kryptex's TLS
# port is 8048 (plain is 7048), so if POOL is the plain Kryptex port, hand
# krig the TLS one instead.
KRIG_HOSTPORT="$POOL_HOSTPORT"
if [ "$POOL_TLS" = 0 ]; then
  KRIG_HOSTPORT="$(echo "$POOL_HOSTPORT" | sed -E 's#^(.*kryptex\.network):7048$#\1:8048#')"
fi
# SRBMiner takes TLS as a flag rather than a URL scheme.
SRB_TLS=""
[ "$POOL_TLS" = 1 ] && SRB_TLS="--tls true"

# Print the miner command for a given name. Every miner spells the algorithm
# differently, so it is hardcoded per miner rather than taken from an env var:
#   krig    --coin pearl        (aliases: prl, pearlhash)
#   srb     --algorithm pearlhash
#   bz      -a pearl
#   wildrig --algo pearlhash
miner_cmd() {
  case "$1" in
    krig)
      # krig's own docs use WALLET/WORKER, not WALLET.WORKER
      echo /opt/krig/krig-miner --coin pearl -o "$KRIG_HOSTPORT" -u "$WALLET/$WORKER_NAME" -p x \
        --no-tui --no-rocm ${KRIG_EXTRA_ARGS:-}
      ;;
    srb)
      echo /opt/srb/SRBMiner-MULTI --algorithm pearlhash --pool "$POOL_HOSTPORT" $SRB_TLS \
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

# Accepted-share detector. Each miner words it differently, and miners also
# print periodic stats containing "accepted" with a zero count, which must
# NOT count:
#   krig     "share accepted: GPU0 108ms"              -> counts
#   krig     "shares: 0 accepted 0 stale 0 rejected"   -> must not count
#   SRBMiner "GPU0[t0] share accepted [ 70ms]"         -> counts
#   WildRig  "Accepted: -" (stats table)               -> must not count
# Rules: "N accepted" needs N>0, "Accepted: N" needs N>0, and anything else
# must be share wording - never bare "accept" (that matched "accepting jobs"
# / "accepted connection" and could lock MINERS onto a miner that isn't hashing).
has_accepted() {
  grep -iE 'accept' "$LOG" 2>/dev/null \
    | grep -viE 'no accepted|not accepted|accepting|accepted connection' \
    | awk '
      { l = tolower($0) }
      l ~ /[0-9]+ accepted/    { if (l ~ /(^|[^0-9.])[1-9][0-9]* accepted/) found = 1; next }
      l ~ /accepted:? *[-0-9]/ { if (l ~ /accepted:? *[1-9]/) found = 1; next }
      l ~ /shares? accepted|accepted shares?|accepted \(|accepted \[|accepted!/ { found = 1 }
      END { exit found ? 0 : 1 }'
}

run_miner() {
  name="$1"
  if [ ! -d "/opt/$name" ]; then
    echo "=== [$name] not installed in this image - skipping ==="
    return 1
  fi
  if [ "$name" = krig ] && [ "$KRIG_OK" = 0 ]; then
    echo "=== [krig] only works with Kryptex pools (POOL=$POOL) - skipping ==="
    return 1
  fi
  : > "$LOG"
  echo "=== [$name] starting: $(miner_cmd "$name") ==="
  cd "/opt/$name"
  # tee -a so the periodic truncation below actually frees space (with plain
  # tee the writer keeps its old offset and the file just goes sparse).
  sh -c "$(miner_cmd "$name")" 2>&1 | tee -a "$LOG" &
  pipeline_pid=$!
  start=$(date +%s)
  confirmed=0
  while :; do
    isleep 10
    alive=1
    kill -0 "$pipeline_pid" 2>/dev/null || alive=0
    # Check the log BEFORE judging an exit, so a miner that got shares and
    # then lost the pool is restarted rather than replaced by the next one.
    if [ "$confirmed" -eq 0 ] && has_accepted; then
      confirmed=1
      echo "=== [$name] ACCEPTED SHARE - this miner works on this node ==="
    fi
    if [ "$alive" -eq 0 ]; then
      wait "$pipeline_pid" 2>/dev/null
      if [ "$confirmed" -eq 1 ]; then
        echo "=== [$name] exited after running successfully ==="
        return 0
      fi
      echo "=== [$name] exited before any accepted share - its last lines were: ==="
      tail -n 8 "$LOG" 2>/dev/null | sed 's/^/    | /'
      return 1
    fi
    if [ "$confirmed" -eq 1 ]; then
      # Miner output keeps flowing to Salad's log via tee's stdout; the file
      # copy is only needed for the share check, so keep it from growing
      # (a few MB/day otherwise, for nothing).
      : > "$LOG"
      continue
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$NO_SHARE_TIMEOUT" ]; then
      echo "=== [$name] no accepted share after ${elapsed}s - killing and trying next miner ==="
      # If the miner WAS getting shares but words it in a way has_accepted
      # doesn't know, these lines are what you need to fix the detector.
      echo "=== [$name] its lines mentioning share/accept (detector input): ==="
      grep -iE 'accept|share' "$LOG" 2>/dev/null | tail -n 8 | sed 's/^/    | /'
      pkill -TERM -f "/opt/$name/" 2>/dev/null
      sleep 3
      pkill -KILL -f "/opt/$name/" 2>/dev/null
      wait "$pipeline_pid" 2>/dev/null
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
  isleep 15
done
