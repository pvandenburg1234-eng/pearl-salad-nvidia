#!/bin/sh
# Shared functions for the Pearl (PRL, pearlhash) SaladCloud images.
# Sourced by entrypoint.sh (production) and bench.sh (benchmark image) so the
# two can't drift apart in miner flags, pool selection or share detection.
#
# Vendor-specific bits (GPU readiness check, krig backend flag, WildRig
# OpenCL platform) key off MINER_VENDOR, which the Dockerfile sets to
# "amd" or "nvidia".
#
# Do NOT export LD_LIBRARY_PATH or PYTHONPATH anywhere - Salad injects them.

MINER_VENDOR="${MINER_VENDOR:-amd}"
# Where the miners live. Only overridden by local tests with fake miners.
MINER_ROOT="${MINER_ROOT:-/opt}"

# ---------------------------------------------------------------------------
# PID 1 plumbing
# ---------------------------------------------------------------------------
# These scripts run as PID 1. Without a trap, PID 1 ignores SIGTERM and a
# Salad stop/reallocation waits out the grace period and SIGKILLs everything.
cleanup() {
  echo "=== SIGTERM received - stopping miner ==="
  pkill -TERM -f "$MINER_ROOT/" 2>/dev/null
  sleep 2
  pkill -KILL -f "$MINER_ROOT/" 2>/dev/null
  ship_stop
  exit 0
}

# Interruptible sleep: a trap can't run while a foreground `sleep` is active,
# so background it and wait (wait IS interruptible).
isleep() { sleep "$1" & wait $! 2>/dev/null; }

# Stop one miner: TERM the miner processes, then KILL, then reap the tee
# pipeline. Killing the pipeline pid (tee) too means a miner that ignores
# signals still dies of SIGPIPE on its next line of output.
kill_miner() {
  name="$1"; pid="$2"
  pkill -TERM -f "$MINER_ROOT/$name/" 2>/dev/null
  sleep 3
  pkill -KILL -f "$MINER_ROOT/$name/" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Log shipping: this container posts its own output to Axiom
# ---------------------------------------------------------------------------
# Salad's external-logging forwarder stopped delivering on 2026-09-25 while
# the containers themselves had working internet, so the container ships its
# own log. With AXIOM_TOKEN set, everything this script prints (its === lines
# and the miner's output) still goes to stdout for Salad's portal, and is also
# appended to $SHIP_LOG; a background loop posts the new lines every
# SHIP_INTERVAL seconds in the record shape Salad's forwarder used
# (@timestamp, log.message, resource.labels.*) plus via="container".
# A line's time is when it was posted (<= SHIP_INTERVAL late), with a
# per-line nanosecond step so the order within a post is kept.
# Shipping never stops mining: a failed post is retried on the next tick, a
# post Axiom rejects (4xx) is dropped, and past SHIP_MAX_BACKLOG unsent bytes
# the backlog is dropped.
#   LOG_SHIP          1 (default) | 0 = off even when AXIOM_TOKEN is set
#   AXIOM_TOKEN       Axiom ingest token (a Salad secret env var); unset = off
#   AXIOM_DATASET     default salad-prl
#   AXIOM_HOST        default us-east-1.aws.edge.axiom.co (the edge host serves
#                     /v1/ingest/<dataset>; api.axiom.co does not)
#   SHIP_INTERVAL     seconds between posts (default 10)
#   SHIP_MAX_BACKLOG  bytes (default 4000000)
SHIP_LOG="${SHIP_LOG:-/tmp/ship.log}"
SHIP_PID=""
ship_start() {
  if [ "${LOG_SHIP:-1}" = 0 ]; then echo "=== log shipping: off (LOG_SHIP=0) ==="; return 0; fi
  [ -n "${AXIOM_TOKEN:-}" ] || return 0
  _fifo="${SHIP_LOG}.fifo"
  rm -f "$_fifo"
  if ! mkfifo "$_fifo"; then echo "=== log shipping: mkfifo failed - off ==="; return 0; fi
  : > "$SHIP_LOG"
  # tee keeps the original stdout (Salad's log) and appends a copy to the
  # file (-a, so truncating the file after a post really frees the space).
  tee -a "$SHIP_LOG" < "$_fifo" &
  exec > "$_fifo" 2>&1
  rm -f "$_fifo"
  ship_loop &
  SHIP_PID=$!
  trap ship_stop EXIT
  echo "=== log shipping: on -> ${AXIOM_HOST:-us-east-1.aws.edge.axiom.co} dataset ${AXIOM_DATASET:-salad-prl} every ${SHIP_INTERVAL:-10}s (LOG_SHIP=0 turns it off) ==="
}

# Final post on the way out (SIGTERM or exit): at most ~5 s.
ship_stop() {
  [ -n "$SHIP_PID" ] || return 0
  kill -TERM "$SHIP_PID" 2>/dev/null
  _i=0
  while [ "$_i" -lt 10 ] && kill -0 "$SHIP_PID" 2>/dev/null; do sleep 0.5; _i=$((_i + 1)); done
  SHIP_PID=""
}

ship_loop() {
  trap 'SHIP_STOPPING=1' TERM
  trap '' INT
  SHIP_STOPPING=0; SHIP_OFF=0; SHIP_FAILS=0
  SHIP_URL="https://${AXIOM_HOST:-us-east-1.aws.edge.axiom.co}/v1/ingest/${AXIOM_DATASET:-salad-prl}"
  SHIP_LABELS="{\"container_group_name\":\"${SALAD_CONTAINER_GROUP_NAME:-}\",\"machine_id\":\"${SALAD_MACHINE_ID:-}\",\"instance_id\":\"${SALAD_INSTANCE_ID:-}\",\"organization_name\":\"${SALAD_ORGANIZATION_NAME:-}\",\"project_name\":\"${SALAD_PROJECT_NAME:-}\",\"image_version\":\"${IMAGE_VERSION:-unknown}\"}"
  while :; do
    [ "$SHIP_STOPPING" = 1 ] || isleep "${SHIP_INTERVAL:-10}"
    ship_once
    # One more pass on the way out in case a post was cut short.
    if [ "$SHIP_STOPPING" = 1 ]; then ship_once; break; fi
  done
}

ship_once() {
  _size=$(wc -c < "$SHIP_LOG" 2>/dev/null) || return 0
  [ "$_size" -lt "$SHIP_OFF" ] && SHIP_OFF=0
  _pend=$((_size - SHIP_OFF))
  [ "$_pend" -gt 0 ] || return 0
  if [ "$_pend" -gt "${SHIP_MAX_BACKLOG:-4000000}" ]; then
    echo "=== log shipping: $_pend bytes unsent (Axiom unreachable?) - dropping them ==="
    SHIP_OFF=$_size
    return 0
  fi
  tail -c +$((SHIP_OFF + 1)) "$SHIP_LOG" | head -c 262144 > "$SHIP_LOG.chunk"
  # Whole lines only; a partial last line waits for the next tick (unless the
  # chunk is one giant line, which goes as is).
  _n=$(tr -dc '\n' < "$SHIP_LOG.chunk" | wc -c)
  if [ "$_n" -gt 0 ]; then head -n "$_n" "$SHIP_LOG.chunk" > "$SHIP_LOG.lines"
  elif [ "$(wc -c < "$SHIP_LOG.chunk")" -ge 262144 ]; then cp "$SHIP_LOG.chunk" "$SHIP_LOG.lines"
  else return 0; fi
  _bytes=$(wc -c < "$SHIP_LOG.lines")
  ship_json < "$SHIP_LOG.lines" > "$SHIP_LOG.json"
  _code=$(curl -s -o "$SHIP_LOG.resp" -w '%{http_code}' --max-time 20 -X POST "$SHIP_URL" \
    -H "Authorization: Bearer $AXIOM_TOKEN" -H 'Content-Type: application/json' \
    --data-binary @"$SHIP_LOG.json" 2>/dev/null)
  case "$_code" in
    2*) SHIP_OFF=$((SHIP_OFF + _bytes))
        if [ "$SHIP_FAILS" -gt 0 ]; then echo "=== log shipping: recovered after $SHIP_FAILS failed posts ==="; fi
        SHIP_FAILS=0 ;;
    4*) SHIP_OFF=$((SHIP_OFF + _bytes)); SHIP_FAILS=$((SHIP_FAILS + 1))
        if [ $((SHIP_FAILS % 60)) = 1 ]; then echo "=== log shipping: Axiom rejected a post (HTTP $_code: $(head -c 200 "$SHIP_LOG.resp")) - dropped; check AXIOM_TOKEN / AXIOM_DATASET ==="; fi ;;
    *)  SHIP_FAILS=$((SHIP_FAILS + 1))
        if [ $((SHIP_FAILS % 60)) = 1 ]; then echo "=== log shipping: post failed (HTTP ${_code:-none}) - retrying ==="; fi ;;
  esac
  # Everything sent and the file is past 1 MB: empty it. (Lines tee appends
  # between the size check and the truncation are lost; it is a microsecond.)
  if [ "$SHIP_OFF" -ge 1000000 ] && [ "$(wc -c < "$SHIP_LOG")" -eq "$SHIP_OFF" ]; then
    : > "$SHIP_LOG"; SHIP_OFF=0
  fi
}

# stdin lines -> JSON array of Axiom events. Control characters other than
# tab and ESC are removed, and bytes >= 0x80 too (one invalid UTF-8 byte
# would make Axiom reject the whole post; miner output is ASCII anyway).
ship_json() {
  _now=$(date -u +%Y-%m-%dT%H:%M:%S.%3N)
  # Escaping is done by GNU sed: awk implementations (mawk in the image,
  # gawk elsewhere) disagree on backslashes in gsub replacements.
  LC_ALL=C tr -d '\000-\010\013-\032\034-\037\200-\377' \
    | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\x1b/\\u001b/g' \
    | LC_ALL=C awk -v now="$_now" -v labels="$SHIP_LABELS" '
    BEGIN { split(now, p, "."); printf "[" }
    {
      t = p[1] "." p[2] sprintf("%06d", NR) "Z"
      printf "%s{\"_time\":\"%s\",\"@timestamp\":\"%s\",\"log\":{\"message\":\"%s\"},\"resource\":{\"type\":\"container\",\"labels\":%s},\"via\":\"container\"}", (NR > 1 ? "," : ""), t, t, $0, labels
    }
    END { print "]" }'
}

# ---------------------------------------------------------------------------
# Wallet / worker
# ---------------------------------------------------------------------------
check_wallet() {
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
}

# ---------------------------------------------------------------------------
# Salad instance metadata service (IMDS): ask to be moved to another node.
# Salad stops this container shortly after a 2xx and temporarily excludes the
# node from the group's pool. Returns 1 when the IMDS isn't reachable (local
# run, or not on Salad) so callers can fall back to just warning.
# ---------------------------------------------------------------------------
salad_reallocate() {
  reason="$1"
  echo "=== asking Salad to reallocate this replica: $reason ==="
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    http://169.254.169.254/v1/reallocate \
    -H 'Content-Type: application/json' -H 'Metadata: true' \
    --data "{\"reason\":\"$reason\"}" 2>/dev/null)"
  case "$code" in
    2*) echo "=== reallocation accepted (HTTP $code) - Salad will stop this container ==="; return 0 ;;
  esac
  echo "=== Salad IMDS not reachable (HTTP ${code:-none}) - not on Salad? carrying on ==="
  return 1
}

# NVIDIA-only: reject a host whose owner has power-capped the card. Salad
# hosts are gaming PCs and some run the GPU at half its TDP to keep it quiet;
# a 3080 Ti at 176 W of 350 W hashed ~20 TH/s instead of ~116. nvidia-smi
# reports both the current and the default limit, so this is knowable in the
# first second rather than after an hour of a fifth of the rate.
#   POWER_CAP_MIN_PCT   reject below this % of the default limit (default 70)
#   POWER_CAP_ACTION    reallocate (default) | warn
# AMD hosts expose none of this under WSL, so gpu_check skips it there.
nvidia_power_check() {
  q="$(nvidia-smi --query-gpu=power.limit,power.default_limit,clocks.max.sm --format=csv,noheader,nounits 2>/dev/null | head -1)"
  limit="$(echo "$q" | awk -F', *' '{print $1}')"
  deflt="$(echo "$q" | awk -F', *' '{print $2}')"
  maxsm="$(echo "$q" | awk -F', *' '{print $3}')"
  case "$limit$deflt" in
    *[!0-9.]*|"") echo "=== NVIDIA power limit: not reported by this driver ($q) - skipping cap check ==="; return 0 ;;
  esac
  pct="$(awk -v l="$limit" -v d="$deflt" 'BEGIN { if (d > 0) printf "%d", l * 100 / d; else print 0 }')"
  echo "=== NVIDIA power limit: ${limit} W of ${deflt} W default (${pct}%), max SM clock ${maxsm:-?} MHz ==="
  min="${POWER_CAP_MIN_PCT:-70}"
  if [ "$pct" -ge "$min" ]; then
    return 0
  fi
  echo "=== HOST IS POWER-CAPPED: ${pct}% < ${min}% - this node will hash far below its class ==="
  if [ "${POWER_CAP_ACTION:-reallocate}" = reallocate ]; then
    if salad_reallocate "GPU power-capped by host: ${limit}W of ${deflt}W (${pct}%)"; then
      # Salad kills the container within a minute or two; don't start a miner
      # that would then be interrupted mid-proof. Wait for the SIGTERM.
      isleep 180
      echo "=== still here after 180s - Salad did not stop us; exiting so the group restarts ==="
      exit 1
    fi
  fi
  echo "=== continuing on the capped host (POWER_CAP_ACTION=${POWER_CAP_ACTION:-reallocate}, IMDS unavailable or action=warn) ==="
}

# Periodic version of the cap check, for hosts that lower the limit AFTER the
# card is under load. A temperature target in the owner's tuning software
# trims the power limit step by step once the card warms up (a 3080 Ti went
# 350 -> 308 -> 242 -> 220 W in its first two minutes), and the driver's own
# thermal slowdown pulls clocks without touching the limit. The startup check
# runs on a cold card and sees neither. The miner loops call this every
# 10 s; it does real work every POWER_CHECK_INTERVAL seconds and acts after
# POWER_CAP_GRACE consecutive bad readings, so a momentary dip costs nothing.
#   POWER_CHECK_INTERVAL  seconds between readings (default 60; 0 disables)
#   POWER_CAP_GRACE       consecutive bad readings before acting (default 3)
#   POWER_CAP_MIN_PCT / POWER_CAP_ACTION as for the startup check
# Usage: host_check_tick MINER_NAME PIPELINE_PID
HOST_CHECK_BAD=0; HOST_CHECK_LAST_PCT=-1; HOST_CHECK_DISABLED=0; HOST_CHECK_NEXT=0; HOST_CHECK_SW_NOTED=0
host_check_tick() {
  [ "$MINER_VENDOR" = nvidia ] || return 0
  [ "$HOST_CHECK_DISABLED" = 1 ] && return 0
  iv="${POWER_CHECK_INTERVAL:-60}"
  [ "$iv" -gt 0 ] 2>/dev/null || return 0
  now="$(date +%s)"
  [ "$now" -lt "$HOST_CHECK_NEXT" ] && return 0
  HOST_CHECK_NEXT=$((now + iv))

  q="$(nvidia-smi --query-gpu=power.limit,power.default_limit,power.draw,temperature.gpu,clocks.sm,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv,noheader,nounits 2>/dev/null | head -1)"
  limit="$(echo "$q" | awk -F', *' '{print $1}')"
  deflt="$(echo "$q" | awk -F', *' '{print $2}')"
  draw="$(echo "$q"  | awk -F', *' '{print $3}')"
  temp="$(echo "$q"  | awk -F', *' '{print $4}')"
  sm="$(echo "$q"    | awk -F', *' '{print $5}')"
  hwt="$(echo "$q"   | awk -F', *' '{print $6}')"
  swt="$(echo "$q"   | awk -F', *' '{print $7}')"
  # Laptops report the power limit as [N/A] (a 5080 Laptop GPU on Salad gave
  # "[N/A], 80.00" while drawing 150 W). Then the percentage test is off, but
  # the thermal checks below still apply - and laptops are exactly where they
  # matter: that card climbed 75 -> 86 C in three minutes.
  have_limit=1
  case "$limit$deflt" in
    *[!0-9.]*|"") have_limit=0 ;;
  esac
  pct=-1
  if [ "$have_limit" = 1 ]; then
    pct="$(awk -v l="$limit" -v d="$deflt" 'BEGIN { if (d > 0) printf "%d", l * 100 / d; else print 0 }')"
  fi

  # Temperature ceiling as a fallback for hosts whose driver reports the
  # slowdown flags as [N/A]. NVIDIA laptop GPUs start pulling clocks at ~87 C.
  #   POWER_TEMP_MAX   degrees C (default 88; 0 disables)
  tmax="${POWER_TEMP_MAX:-88}"

  bad=0; why=""
  if [ "$have_limit" = 1 ] && [ "$pct" -lt "${POWER_CAP_MIN_PCT:-70}" ]; then
    bad=1; why="power limit ${limit}W of ${deflt}W (${pct}%)"
  fi
  # Thermal flags. On a desktop card (power limit reported) either flag means
  # the host is cutting the card under load. On a laptop (no limit reported)
  # the SOFTWARE flag is just the firmware holding its temperature target: a
  # 5080 Laptop on Salad reported sw=Active while sitting at 123-127 W, 84 C,
  # 1950 MHz and 105 TH/s, and v1.5.0 threw that host away after 3 minutes.
  # So on laptops only the hardware flag and the temperature ceiling count;
  # the software flag is noted once for the record.
  if [ "$hwt" = Active ]; then
    bad=1; why="${why:+$why, }hardware thermal slowdown active (hw=${hwt} sw=${swt})"
  elif [ "$swt" = Active ]; then
    if [ "$have_limit" = 1 ]; then
      bad=1; why="${why:+$why, }thermal slowdown active (hw=${hwt} sw=${swt})"
    elif [ "$HOST_CHECK_SW_NOTED" = 0 ]; then
      HOST_CHECK_SW_NOTED=1
      echo "=== host check: software thermal slowdown reported at ${draw:-?}W, ${temp:-?}C, SM ${sm:-?} MHz - normal for a laptop holding its temperature target, not counted; the ${tmax}C ceiling and the hardware flag still apply ==="
    fi
  fi
  case "$temp" in
    ''|*[!0-9]*) ;;
    *) if [ "$tmax" -gt 0 ] 2>/dev/null && [ "$temp" -ge "$tmax" ]; then
         bad=1; why="${why:+$why, }GPU at ${temp}C (ceiling ${tmax})"
       fi ;;
  esac

  if [ "$bad" = 1 ]; then
    HOST_CHECK_BAD=$((HOST_CHECK_BAD + 1))
    echo "=== host check: $why; drawing ${draw:-?}W, ${temp:-?}C, SM ${sm:-?} MHz - bad reading ${HOST_CHECK_BAD}/${POWER_CAP_GRACE:-3} ==="
    if [ "$HOST_CHECK_BAD" -ge "${POWER_CAP_GRACE:-3}" ]; then
      echo "=== HOST IS THROTTLING: $why for ${HOST_CHECK_BAD} consecutive readings ==="
      if [ "${POWER_CAP_ACTION:-reallocate}" = reallocate ]; then
        if salad_reallocate "GPU throttled by host: $why"; then
          [ -n "${2:-}" ] && kill_miner "$1" "$2"
          isleep 180
          echo "=== still here after 180s - Salad did not stop us; exiting so the group restarts ==="
          exit 1
        fi
      fi
      echo "=== continuing on the throttled host (POWER_CAP_ACTION=${POWER_CAP_ACTION:-reallocate}, IMDS unavailable or action=warn); periodic check off ==="
      HOST_CHECK_DISABLED=1
    fi
  else
    [ "$HOST_CHECK_BAD" -gt 0 ] && echo "=== host check: recovered - drawing ${draw:-?}W, ${temp:-?}C, SM ${sm:-?} MHz${have_limit:+, limit ${limit}W of ${deflt}W} ==="
    HOST_CHECK_BAD=0
    # Heartbeat only when the limit has moved by 5 points or more, so a
    # steady host adds nothing to the Salad log. (No limit reported: no heartbeat.)
    if [ "$have_limit" = 1 ]; then
      d=$((pct - HOST_CHECK_LAST_PCT)); [ "$d" -lt 0 ] && d=$((0 - d))
      if [ "$HOST_CHECK_LAST_PCT" -ge 0 ] && [ "$d" -ge 5 ]; then
        echo "=== host check: power limit ${limit}W of ${deflt}W (${pct}%), drawing ${draw:-?}W, ${temp:-?}C, SM ${sm:-?} MHz ==="
      fi
      HOST_CHECK_LAST_PCT="$pct"
    fi
  fi
}

# ---------------------------------------------------------------------------
# GPU readiness check. Sets GPU_DESC (gfx target on AMD, card name on NVIDIA).
# ---------------------------------------------------------------------------
gpu_check() {
  GPU_DESC=""
  if [ "$MINER_VENDOR" = nvidia ]; then
    echo "=== GPU readiness check (nvidia-smi) ==="
    echo "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-<unset>}  NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-<unset>}"
    if command -v nvidia-smi >/dev/null 2>&1; then
      if nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1; then
        GPU_DESC="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
        nvidia_power_check
      else
        echo "nvidia-smi failed - the host driver was not injected. Is this an NVIDIA GPU class?"
      fi
    else
      echo "nvidia-smi not found - the container toolkit did not inject the driver. Is this an NVIDIA GPU class?"
    fi
    echo "=== GPU: ${GPU_DESC:-unknown} ==="
    echo "=== OpenCL platforms (clinfo) - only matters for WildRig ==="
  else
    echo "=== GPU readiness check (rocminfo) ==="
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
    if command -v rocminfo >/dev/null 2>&1; then
      ROCMINFO="$(rocminfo 2>&1)"
      echo "$ROCMINFO" | grep -E 'Name:|Marketing Name|gfx|HSA_STATUS' | head -20
      GPU_DESC="$(echo "$ROCMINFO" | grep -oE 'gfx[0-9a-f]+' | head -1)"
    else
      echo "rocminfo not found in image (unexpected)"
    fi
    echo "=== GPU arch: ${GPU_DESC:-unknown} ==="
    echo "=== OpenCL platforms (clinfo) ==="
  fi
  clinfo -l 2>&1 | head -20 || true
}

# ---------------------------------------------------------------------------
# Pool selection
# ---------------------------------------------------------------------------
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

# resolve_pool: run the region probe (if enabled), then derive everything the
# miner commands need from the final POOL:
#   KRIG_OK        krig-miner only mines on Kryptex
#   POOL_HOSTPORT  host:port without scheme
#   POOL_TLS       1 if the scheme is stratum+ssl / stratum+tls
#   KRIG_HOSTPORT  krig only speaks TLS: Kryptex 7048 -> 8048
#   SRB_TLS        "--tls true" when POOL_TLS
resolve_pool() {
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
}

# ---------------------------------------------------------------------------
# Pool reachability. Two Salad laptop hosts in one day could not mine at all:
# one where the TCP probe succeeded but no TLS handshake to port 8048 ever
# completed (BzMiner: "TLS connect failed"; SRBMiner silent), and one where
# something on the network intercepted TLS (the region probe read 1-4 ms to
# every region on earth; krig then refused the pool as "not the official
# Kryptex PRL pool" because the certificate wasn't Kryptex's). Neither host
# was worth a single miner window, let alone the production image's
# retry-forever loop.
#
# pool_check: sets POOL_STATE to one of
#   ok           handshake + certificate verify (or plain TCP connect for
#                non-TLS pools)
#   intercepted  handshake works but the certificate does not verify: SRBMiner
#                and BzMiner will mine, krig will refuse - so krig is skipped
#   unreachable  no handshake (or no connect) to the chosen endpoint AND to
#                the pool's global endpoint
# Kryptex's stratum certificate verifies against public CAs (checked
# 2026-09-25), so a verify failure really does mean interception.
#   POOL_CHECK=0 disables.
pool_check() {
  POOL_STATE=ok
  [ "${POOL_CHECK:-1}" = 1 ] || return 0
  if [ "$POOL_TLS" = 1 ]; then
    _tls_probe "$POOL_HOSTPORT"; st=$?
    if [ "$st" = 2 ]; then
      # Try the pool's global name once before giving up on the host.
      alt="$(echo "$POOL_HOSTPORT" | sed -E 's#^prl(-[a-z0-9]+)?\.kryptex\.network#prl.kryptex.network#')"
      if [ "$alt" != "$POOL_HOSTPORT" ]; then
        echo "=== pool check: $POOL_HOSTPORT unreachable over TLS, trying $alt ==="
        _tls_probe "$alt"; st=$?
        if [ "$st" != 2 ]; then
          POOL="$(echo "$POOL" | sed "s#$POOL_HOSTPORT#$alt#")"; POOL_HOSTPORT="$alt"; KRIG_HOSTPORT="$alt"
        fi
      fi
    fi
    case "$st" in
      0) echo "=== pool check: TLS handshake and certificate OK ($POOL_HOSTPORT) ===" ;;
      1) POOL_STATE=intercepted
         echo "=== pool check: TLS handshake works but the certificate does NOT verify ($POOL_HOSTPORT) - this network intercepts TLS ==="
         echo "=== pool check: SRBMiner/BzMiner can mine through it; krig would refuse the pool, so krig is skipped on this host ==="
         KRIG_OK=0 ;;
      *) POOL_STATE=unreachable
         echo "=== pool check: no TLS handshake to $POOL_HOSTPORT (curl exit $_tls_rc) - this host cannot reach the pool ===" ;;
    esac
  else
    t="$(curl -s -o /dev/null --max-time 6 -w '%{time_connect}' "telnet://$POOL_HOSTPORT" 2>/dev/null </dev/null)"
    ms="$(echo "${t:-0}" | awk '{ printf "%d", $1 * 1000 }')"
    if [ "$ms" -gt 0 ]; then
      echo "=== pool check: TCP connect OK ($POOL_HOSTPORT, ${ms} ms) ==="
    else
      POOL_STATE=unreachable
      echo "=== pool check: cannot connect to $POOL_HOSTPORT - this host cannot reach the pool ==="
    fi
  fi
  [ "$POOL_STATE" = unreachable ] && return 1
  return 0
}

# _tls_probe HOST:PORT -> 0 ok, 1 handshake-but-no-verify, 2 no handshake.
# curl treats the stratum server as an HTTPS server that sends no HTTP reply:
# exit 52/56/55 after a completed handshake are all "ok" here.
_tls_probe() {
  curl -s -o /dev/null --max-time 8 "https://$1/" 2>/dev/null; _tls_rc=$?
  case "$_tls_rc" in
    0|52|55|56|18|8) return 0 ;;
    60|51|58|59)     # certificate problem: does a handshake work at all?
      curl -s -o /dev/null --max-time 8 -k "https://$1/" 2>/dev/null; _tls_rc2=$?
      case "$_tls_rc2" in 0|52|55|56|18|8) return 1 ;; *) _tls_rc=$_tls_rc2; return 2 ;; esac ;;
    *) return 2 ;;
  esac
}

# Convenience for the entrypoints: check, and hand the node back if the pool
# is unreachable (falls through with a warning when the IMDS isn't there).
pool_check_or_reallocate() {
  pool_check && return 0
  if salad_reallocate "pool $POOL_HOSTPORT unreachable from this host (curl exit ${_tls_rc:-?})"; then
    isleep 180
    echo "=== still here after 180s - Salad did not stop us; exiting so the group restarts ==="
    exit 1
  fi
  echo "=== continuing anyway (IMDS unavailable); the miners will most likely all time out ==="
  return 1
}

# ---------------------------------------------------------------------------
# Miners
# ---------------------------------------------------------------------------
# Print the miner command for a given name. Every miner spells the algorithm
# differently, so it is hardcoded per miner rather than taken from an env var:
#   krig    --coin pearl        (aliases: prl, pearlhash)
#   srb     --algorithm pearlhash
#   bz      -a pearl
#   wildrig --algo pearlhash
miner_cmd() {
  if [ "$MINER_VENDOR" = nvidia ]; then
    krig_backend="--no-rocm"; wildrig_platform="nvidia"
  else
    krig_backend="--no-cuda"; wildrig_platform="amd"
  fi
  case "$1" in
    krig)
      # krig's own docs use WALLET/WORKER, not WALLET.WORKER
      echo "$MINER_ROOT/krig/krig-miner" --coin pearl -o "$KRIG_HOSTPORT" -u "$WALLET/$WORKER_NAME" -p x \
        --no-tui "$krig_backend" ${KRIG_EXTRA_ARGS:-}
      ;;
    srb)
      echo "$MINER_ROOT/srb/SRBMiner-MULTI" --algorithm pearlhash --pool "$POOL_HOSTPORT" $SRB_TLS \
        --wallet "$USER_ARG" --password x --disable-cpu \
        ${SRB_EXTRA_ARGS:-}
      ;;
    bz)
      # BzMiner reprints a ~15-line device table every 30 s by default. Five
      # nodes of that fill Salad's 1000-row group log view in ~20 minutes and
      # it stops scrolling. Its one-line "pearl hashrate N shares=N" summary
      # still comes every 60 s, which is all the detector/parser need, so
      # print the table every 5 min in production (bench.sh uses 60 s).
      echo "$MINER_ROOT/bz/bzminer" -a pearl -p "$POOL" -w "$WALLET" --worker "$WORKER_NAME" \
        --pass x --cpu 0 --no-color --log-table-interval "${BZ_TABLE_INTERVAL_MS:-300000}" \
        ${BZ_EXTRA_ARGS:-}
      ;;
    wildrig)
      echo "$MINER_ROOT/wildrig/wildrig-multi" --algo pearlhash --url "$POOL" --user "$USER_ARG" \
        --pass x --opencl-platforms "$wildrig_platform" --no-adl --no-igcl --no-sysfs \
        ${WILDRIG_EXTRA_ARGS:-}
      ;;
    *)
      echo "echo unknown miner '$1'; false"
      ;;
  esac
}

# Devfee in percent. Devfee is taken as mining time, so a miner's reported
# hashrate has to be scaled by (100 - devfee) to compare what actually pays.
miner_devfee() {
  case "$1" in
    krig)    echo 0 ;;   # Kryptex's own miner
    srb)     echo 2 ;;   # SRBMiner-MULTI pearlhash
    bz)      echo 2 ;;   # BzMiner pearl
    wildrig) echo 0 ;;   # WildRig pearlhash (0% "on the miner side")
    *)       echo 0 ;;
  esac
}

# Why a miner can't run here, or empty if it can.
miner_skip_reason() {
  if [ ! -d "$MINER_ROOT/$1" ]; then
    echo "not installed in this image"
  elif [ "$1" = krig ] && [ "${KRIG_OK:-0}" = 0 ]; then
    echo "only works with Kryptex pools (POOL=$POOL)"
  fi
}

# ---------------------------------------------------------------------------
# Log parsers. All take a log file path.
# ---------------------------------------------------------------------------
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
#   BzMiner  "pearl hashrate 34.12th  shares=0"       -> must not count (seen on Salad)
#   BzMiner  "... shares=3"                            -> counts
has_accepted() {
  grep -iE 'accept|shares=' "$1" 2>/dev/null \
    | grep -viE 'no accepted|not accepted|accepting|accepted connection' \
    | awk '
      { l = tolower($0); gsub(/\033\[[0-9;]*[a-z]/, "", l) }
      l ~ /shares=[0-9]+/      { if (l ~ /shares=[1-9]/) found = 1; next }
      l ~ /[0-9]+ accepted/    { if (l ~ /(^|[^0-9.])[1-9][0-9]* accepted/) found = 1; next }
      l ~ /accepted:? *[-0-9]/ { if (l ~ /accepted:? *[1-9]/) found = 1; next }
      l ~ /shares? accepted|accepted shares?|accepted \(|accepted \[|accepted!/ { found = 1 }
      END { exit found ? 0 : 1 }'
}

# Best-effort accepted-share COUNT, same rules as has_accepted: the highest
# running counter seen ("N accepted" / "Accepted: N"), or the number of
# per-share lines, whichever is larger.
count_accepted() {
  grep -iE 'accept|shares=' "$1" 2>/dev/null \
    | grep -viE 'no accepted|not accepted|accepting|accepted connection' \
    | awk '
      { l = tolower($0); gsub(/\033\[[0-9;]*[a-z]/, "", l) }
      l ~ /shares=[0-9]+/ {
        match(l, /shares=[0-9]+/); s = substr(l, RSTART + 7, RLENGTH - 7) + 0
        if (s > maxc) maxc = s; next }
      l ~ /[0-9]+ accepted/ {
        match(l, /[0-9]+ accepted/); n = substr(l, RSTART, RLENGTH) + 0
        if (n > maxc) maxc = n; next }
      l ~ /accepted:? *[0-9]+/ {
        match(l, /accepted:? *[0-9]+/); s = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", s)
        if (s + 0 > maxc) maxc = s + 0; next }
      l ~ /shares? accepted|accepted shares?|accepted \(|accepted \[|accepted!/ { cnt++ }
      END { print (cnt > maxc ? cnt : maxc) + 0 }'
}

# Reported hashrate in TH/s: prints "<median> <samples>". Each miner prints
# its rate differently, so this is deliberately loose. Formats seen on Salad:
#   krig     "Total: 51.87 TH/s shares: 0 accepted ..."   and a per-GPU line
#   SRBMiner "#0  Radeon RX 9060 XT   42.27 TH/s ..."     plus "1 hr 0.00 H/s"
#            averages that are zero until the window fills
#   BzMiner  "| smry | ... | 34.07th | ..."  and  "pearl hashrate 34.12th"
#            (unit "th" with no "/s"; "pool hr | --" columns have no number)
#   WildRig  "n/a TH/s" when it can't hash; documented "speed 10s/60s/15m
#            51.0 50.9 n/a TH/s" has the number well before the unit
# Rules:
#   * ANSI colour codes are stripped first (SRBMiner and WildRig use them)
#   * lines about the network/pool rate are skipped
#   * "<number> <unit>H/s" or "<number><k|m|g|t|p>h" anywhere is a sample;
#     on a "speed" line without one, the first numeric token after "speed"
#   * zero samples are dropped (SRBMiner's unfilled averages)
#   * if any line says "total" or "smry", only those lines are used (krig and
#     BzMiner print a per-GPU line AND a summary line; don't double count)
#   * the first SKIP samples are dropped as warm-up, then the median is taken
# Usage: parse_hashrate FILE [SKIP]
parse_hashrate() {
  awk -v skip="${2:-2}" '
    function mult(u) {
      u = tolower(u)
      if (u ~ /^ph/) return 1000
      if (u ~ /^th/) return 1
      if (u ~ /^gh/) return 0.001
      if (u ~ /^mh/) return 0.000001
      if (u ~ /^kh/) return 0.000000001
      return 0.000000000001
    }
    {
      l = tolower($0)
      gsub(/\033\[[0-9;]*[a-z]/, "", l)
      if (l !~ /h\/s|[0-9][kmgtp]h([^a-z]|$)/) next
      if (l ~ /network|difficulty|pool hashrate|pool speed/) next
      v = ""; u = ""
      # The BzMiner summary row has "| pool hr | miner hr |" - two rates, and
      # the pool-side estimate comes first ("148.54th | 126.66th"). We want
      # the figure the miner measured itself, so on those rows take the LAST
      # rate found. (No apostrophes in here: this is inside a single-quoted
      # shell string.)
      rest = l; last = ""
      while (match(rest, /[0-9]+(\.[0-9]+)? *[kmgtp]?h\/s/) || match(rest, /[0-9]+(\.[0-9]+)?[kmgtp]h([^a-z]|$)/)) {
        last = substr(rest, RSTART, RLENGTH)
        if (l !~ /smry|miner hr/) break
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (last != "") {
        s = last
        match(s, /[0-9]+(\.[0-9]+)?/); v = substr(s, RSTART, RLENGTH)
        u = substr(s, RSTART + RLENGTH); gsub(/^ +/, "", u)
      } else if (l ~ /speed/) {
        n = split(l, tok, /[ \t]+/); seen = 0
        for (i = 1; i <= n; i++) {
          if (seen && tok[i] ~ /^[0-9]+(\.[0-9]+)?$/) { v = tok[i]; break }
          if (tok[i] ~ /speed/) seen = 1
        }
        if (match(l, /[kmgtp]?h\/s/)) u = substr(l, RSTART, RLENGTH)
      }
      if (v == "") next
      ths = v * mult(u)
      if (ths <= 0) next
      if (l ~ /total|smry|pearl hashrate/) tot[++nt] = ths; else all[++na] = ths
    }
    END {
      if (nt > 0) { n = nt; for (i = 1; i <= n; i++) a[i] = tot[i] }
      else        { n = na; for (i = 1; i <= n; i++) a[i] = all[i] }
      if (n <= skip) { print "0 0"; exit }
      m = 0
      for (i = skip + 1; i <= n; i++) b[++m] = a[i]
      for (i = 2; i <= m; i++) { x = b[i]; j = i - 1; while (j > 0 && b[j] > x) { b[j+1] = b[j]; j-- } b[j+1] = x }
      med = (m % 2) ? b[(m + 1) / 2] : (b[m / 2] + b[m / 2 + 1]) / 2
      printf "%.2f %d\n", med, m
    }' "$1" 2>/dev/null
}
