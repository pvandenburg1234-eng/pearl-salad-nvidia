#!/bin/sh
# Benchmark entrypoint for the Pearl (PRL, pearlhash) SaladCloud images.
# Published as the *-bench image. Run it in a one-replica group on a GPU
# class when you want to know which bundled miner is fastest on that card,
# e.g. after a miner ships a big update.
#
# For each miner in $MINERS it mines for BENCH_SECONDS, parses the hashrate
# the miner reports, applies that miner's devfee, and prints a table plus a
# MINERS=... recommendation for the production group. The shares it finds
# go to your WALLET like any other mining. Afterwards (BENCH_THEN):
#   mine  (default)  keep mining with the winner until the group is stopped,
#                    so the paid node time isn't wasted
#   hold             idle for BENCH_HOLD seconds printing the table, then exit
#   exit             exit 0 right away (Salad restarts the container, which
#                    re-runs the benchmark - stop the group when you've read it)
#
# Env: WALLET (required), POOL / POOL_AUTO as production, MINERS (order to
# test; default all four), BENCH_SECONDS (300), BENCH_SKIP_SAMPLES (2 - warm-up
# samples ignored), BENCH_THEN, BENCH_HOLD (3600), *_EXTRA_ARGS as production.

set -u
. "$(dirname "$0")/common.sh"

trap cleanup TERM INT
check_wallet

MINERS="${MINERS:-krig srb bz wildrig}"
BENCH_SECONDS="${BENCH_SECONDS:-300}"
BENCH_SKIP_SAMPLES="${BENCH_SKIP_SAMPLES:-2}"
BENCH_THEN="${BENCH_THEN:-mine}"
BENCH_HOLD="${BENCH_HOLD:-3600}"
LOG=/tmp/miner.log
RESULTS=/tmp/bench.results

echo "=== pearl-salad-bench ($MINER_VENDOR) image version: ${IMAGE_VERSION:-unknown} ==="
gpu_check
if [ -z "$GPU_DESC" ]; then
  echo "=== No GPU detected - nothing to benchmark. Exiting. ==="
  exit 1
fi
resolve_pool
echo "=== Benchmark: $BENCH_SECONDS s per miner, order: $MINERS ==="

: > "$RESULTS"

# record NAME STATUS THS SAMPLES SHARES
record() {
  fee="$(miner_devfee "$1")"
  eff="$(awk -v t="$3" -v f="$fee" 'BEGIN { printf "%.2f", t * (100 - f) / 100 }')"
  printf '%s %s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$fee" "$eff" >> "$RESULTS"
}

bench_miner() {
  name="$1"
  reason="$(miner_skip_reason "$name")"
  if [ -n "$reason" ]; then
    echo "=== [$name] $reason - skipping ==="
    record "$name" skipped 0 0 0
    return
  fi
  : > "$LOG"
  echo "=== [$name] benchmark start: $(miner_cmd "$name") ==="
  cd "$MINER_ROOT/$name"
  sh -c "$(miner_cmd "$name")" 2>&1 | tee -a "$LOG" &
  pipeline_pid=$!
  start=$(date +%s)
  status=ok
  while :; do
    isleep 10
    if ! kill -0 "$pipeline_pid" 2>/dev/null; then
      wait "$pipeline_pid" 2>/dev/null
      echo "=== [$name] exited on its own after $(( $(date +%s) - start ))s ==="
      status=exited
      break
    fi
    [ $(( $(date +%s) - start )) -ge "$BENCH_SECONDS" ] && break
  done
  [ "$status" = ok ] && kill_miner "$name" "$pipeline_pid"

  set -- $(parse_hashrate "$LOG" "$BENCH_SKIP_SAMPLES")
  ths="${1:-0}"; samples="${2:-0}"
  shares="$(count_accepted "$LOG")"
  if [ "$samples" -eq 0 ]; then
    status=failed
    echo "=== [$name] no hashrate reported. Its lines mentioning H/s, share or accept: ==="
    grep -iE 'h/s|share|accept|error|fail' "$LOG" 2>/dev/null | tail -n 10 | sed 's/^/    | /'
  fi
  echo "=== [$name] result: $status, ${ths} TH/s (median of $samples samples), $shares accepted share(s) ==="
  record "$name" "$status" "$ths" "$samples" "$shares"
}

for m in $MINERS; do
  bench_miner "$m"
done

print_table() {
  echo "=================================================================================="
  echo " Pearl miner benchmark  -  GPU: ${GPU_DESC:-unknown}  -  pool: $POOL"
  echo " ${BENCH_SECONDS}s per miner, median of reported rate after ${BENCH_SKIP_SAMPLES} warm-up samples"
  echo "=================================================================================="
  printf ' %-8s %-8s %12s %8s %7s %7s %14s\n' MINER STATUS "REPORTED TH/s" SAMPLES SHARES DEVFEE "EFFECTIVE TH/s"
  while read -r n st t s sh fee eff; do
    printf ' %-8s %-8s %12s %8s %7s %6s%% %14s\n' "$n" "$st" "$t" "$s" "$sh" "$fee" "$eff"
  done < "$RESULTS"
  echo "----------------------------------------------------------------------------------"
}

# Winner: highest effective rate. A miner within 3% of the top is a tie, and
# ties go to the lower devfee (pool-side rate is what pays, and reported
# rates are only accurate to a few percent).
best="$(awk '
  $2 == "ok" && $7 + 0 > 0 { eff[$1] = $7 + 0; fee[$1] = $6 + 0; if ($7 + 0 > top) top = $7 + 0 }
  END {
    for (n in eff) if (eff[n] >= top * 0.97) {
      if (best == "" || fee[n] < fee[best] || (fee[n] == fee[best] && eff[n] > eff[best])) best = n
    }
    print best
  }' "$RESULTS")"

print_table
if [ -n "$best" ]; then
  echo " RECOMMENDED for this GPU class:  MINERS=$best"
else
  echo " No miner produced a hashrate on this node. Nothing to recommend."
fi
echo "=================================================================================="

case "$BENCH_THEN" in
  exit)
    exit 0 ;;
  hold)
    end=$(( $(date +%s) + BENCH_HOLD ))
    while [ "$(date +%s)" -lt "$end" ]; do
      echo "=== benchmark finished; holding ($(( (end - $(date +%s)) / 60 )) min left). Stop the container group when you've read the table. ==="
      isleep 60
    done
    exit 0 ;;
  *)
    if [ -z "$best" ]; then
      echo "=== nothing to mine with; exiting ==="
      exit 1
    fi
    echo "=== benchmark finished; mining with $best until the group is stopped ==="
    # Pool is already resolved; don't re-probe.
    MINERS="$best" POOL="$POOL" POOL_AUTO=0 exec "$(dirname "$0")/entrypoint.sh" ;;
esac
