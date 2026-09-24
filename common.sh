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
