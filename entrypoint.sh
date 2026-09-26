#!/bin/sh
# Production entrypoint for the Pearl (PRL, pearlhash) SaladCloud images
# (AMD or NVIDIA - see MINER_VENDOR, set by the Dockerfile).
# Do NOT export LD_LIBRARY_PATH or PYTHONPATH here - Salad injects them.
#
# Tries each miner in $MINERS in order. A miner "works" once it logs an
# accepted share; if it exits, or produces no accepted share within
# $NO_SHARE_TIMEOUT seconds, it is killed and the next miner is tried.
# (WildRig under ROCm OpenCL can run forever without hashing - hence the
# share-based check rather than an exit-code check.)
#
# Pool selection, miner commands and the share detector live in common.sh,
# shared with bench.sh (the benchmark image) so the two can't drift.

set -u
. "$(dirname "$0")/common.sh"

trap cleanup TERM INT
ship_start
check_wallet

MINERS="${MINERS:-krig srb bz wildrig}"
# Pearl shares are STARK proofs; on a weak card at a not-yet-adjusted pool
# difficulty the first one can take several minutes, so give it 10.
NO_SHARE_TIMEOUT="${NO_SHARE_TIMEOUT:-600}"
LOG=/tmp/miner.log

echo "=== pearl-salad ($MINER_VENDOR) image version: ${IMAGE_VERSION:-unknown} ==="
gpu_check
echo "=== miner order: $MINERS ==="
resolve_pool
pool_check_or_reallocate

run_miner() {
  name="$1"
  reason="$(miner_skip_reason "$name")"
  if [ -n "$reason" ]; then
    echo "=== [$name] $reason - skipping ==="
    return 1
  fi
  RAN_ANY=1
  : > "$LOG"
  echo "=== [$name] starting: $(miner_cmd "$name") ==="
  cd "$MINER_ROOT/$name"
  # tee -a so the periodic truncation below actually frees space (with plain
  # tee the writer keeps its old offset and the file just goes sparse).
  sh -c "$(miner_cmd "$name")" 2>&1 | tee -a "$LOG" &
  pipeline_pid=$!
  start=$(date +%s)
  confirmed=0
  while :; do
    isleep 10
    host_check_tick "$name" "$pipeline_pid"
    alive=1
    kill -0 "$pipeline_pid" 2>/dev/null || alive=0
    # Check the log BEFORE judging an exit, so a miner that got shares and
    # then lost the pool is restarted rather than replaced by the next one.
    if [ "$confirmed" -eq 0 ] && has_accepted "$LOG"; then
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
      kill_miner "$name" "$pipeline_pid"
      return 1
    fi
  done
}

# A node where every miner fails is a node that can't mine (bad network, bad
# driver, GPU gone). Before this the loop retried forever, billing the whole
# time. After MAX_FAILED_PASSES full passes with no accepted share from any
# miner that actually ran, hand the node back. A pass where nothing ran at
# all (every miner skipped) is a configuration problem, not a bad node, so it
# is logged and retried instead.
#   MAX_FAILED_PASSES   default 1 (= NO_SHARE_TIMEOUT x miners that ran)
FAILED_PASSES=0
while :; do
  RAN_ANY=0; PASS_OK=0
  for m in $MINERS; do
    if run_miner "$m"; then
      # It worked then died (pool drop / node hiccup): stick with this miner.
      MINERS="$m"
      PASS_OK=1
      break
    fi
  done
  if [ "$PASS_OK" = 1 ]; then
    FAILED_PASSES=0
  elif [ "$RAN_ANY" = 0 ]; then
    echo "=== no miner could even start (all skipped) - check MINERS and POOL; retrying, not reallocating ==="
  else
    FAILED_PASSES=$((FAILED_PASSES + 1))
    echo "=== no miner produced an accepted share this pass (${FAILED_PASSES}/${MAX_FAILED_PASSES:-1}) ==="
    if [ "$FAILED_PASSES" -ge "${MAX_FAILED_PASSES:-1}" ]; then
      if salad_reallocate "no miner produced a share after $FAILED_PASSES full pass(es) of $MINERS"; then
        isleep 180
        echo "=== still here after 180s - Salad did not stop us; exiting so the group restarts ==="
        exit 1
      fi
      echo "=== IMDS unavailable - will keep retrying on this node ==="
    fi
  fi
  echo "=== restarting in 15s ==="
  isleep 15
done
