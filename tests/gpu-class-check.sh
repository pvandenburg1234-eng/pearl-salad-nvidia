#!/bin/sh
# Test gpu_class_check (common.sh) with stubs - no GPU, no Salad needed.
# Run with the shell the images use:  dash tests/gpu-class-check.sh  (CI: build.yml)
# Each case runs in a subshell; the check's own "exit 1" (after a reallocate) ends
# only that subshell. Prints one line per case, exits 1 if any case fails.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(sed -n '/^gpu_class_check() {/,/^}/p' "$here/common.sh")"
isleep() { :; }
REALLOC_OK=0
salad_reallocate() { echo "STUB-REALLOCATE: $1"; return "$REALLOC_OK"; }

fails=0
# case NAME EXPECT(ok|wrong|skip|none) VENDOR GPU_DESC GPU_NAMES ROCMINFO EXPECT_GPU [ACTION] [REALLOC_RC]
case_() {
  name=$1; want=$2
  out="$(MINER_VENDOR=$3 GPU_DESC=$4 GPU_NAMES=$5 ROCMINFO=$6 EXPECT_GPU=$7 EXPECT_GPU_ACTION=${8:-reallocate} REALLOC_OK=${9:-0} \
    sh -c 'eval "$(sed -n "/^gpu_class_check() {/,/^}/p" "$1/common.sh")"; isleep() { :; }; salad_reallocate() { echo "STUB-REALLOCATE: $1"; return "$REALLOC_OK"; }; gpu_class_check; echo "RC-AFTER"' _ "$here" 2>&1)"
  rc=$?
  got=none
  case "$out" in *"GPU class check: OK"*) got=ok ;; *"WRONG GPU"*) got=wrong ;; *"GPU class check skipped"*) got=skip ;; esac
  # a wrong card with reallocate must stop the container (exit 1, nothing after it runs)
  if [ "$got" = wrong ] && [ "${8:-reallocate}" = reallocate ] && [ "${9:-0}" = 0 ]; then
    { [ "$rc" -eq 1 ] && ! echo "$out" | grep -q RC-AFTER && echo "$out" | grep -q STUB-REALLOCATE; } || got="wrong-but-did-not-stop(rc=$rc)"
  fi
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: want $want, got $got"; echo "$out" | sed 's/^/     | /'; fails=$((fails + 1)); fi
}

R9070='  Name:                    AMD Ryzen 7 5700X 8-Core Processor
  Marketing Name:          AMD Ryzen 7 5700X 8-Core Processor
  Name:                    gfx1201
  Marketing Name:          AMD Radeon RX 9070 XT    '
R9060='  Marketing Name:          AMD Ryzen 7 7800X3D 8-Core Processor
  Marketing Name:          AMD Radeon RX 9060 XT'
N5090='NVIDIA GeForce RTX 5090'
P5090='RTX 5090( D)?$'

case_ "3060 in a 5090 group -> reallocate"            wrong nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060" "" "$P5090"
case_ "real 5090 -> ok"                               ok    nvidia "$N5090" "$N5090" "" "$P5090"
case_ "5090 D -> ok"                                  ok    nvidia "NVIDIA GeForce RTX 5090 D" "NVIDIA GeForce RTX 5090 D" "" "$P5090"
case_ "5090 Laptop in a desktop group -> reallocate"  wrong nvidia "NVIDIA GeForce RTX 5090 Laptop GPU" "NVIDIA GeForce RTX 5090 Laptop GPU" "" "$P5090"
case_ "4090 in a (5090|4090) group -> ok"             ok    nvidia "NVIDIA GeForce RTX 4090" "NVIDIA GeForce RTX 4090" "" '(5090|4090)$'
case_ "two GPUs, 3060 first, 5090 second -> ok"       ok    nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060
$N5090" "" "$P5090"
case_ "two GPUs, neither a 5090 -> reallocate"        wrong nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060
NVIDIA GeForce RTX 3070" "" "$P5090"
case_ "GPU_NAMES unset (old path) -> uses GPU_DESC"   ok    nvidia "$N5090" "" "" "$P5090"
case_ "nvidia-smi failed (no GPU_DESC) -> skip"       skip  nvidia "" "" "" "$P5090"
case_ "invalid pattern -> skip, never reallocate"     skip  nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060" "" 'RTX (5090'
case_ "9070 XT by gfx -> ok"                          ok    amd "gfx1201" "" "$R9070" "gfx1201"
case_ "9070 XT by name -> ok"                         ok    amd "gfx1201" "" "$R9070" "RX 9070 XT$"
case_ "9060 XT in a 9070 XT group -> reallocate"      wrong amd "gfx1200" "" "$R9060" "gfx1201"
case_ "AMD, rocminfo missed it (no GPU_DESC) -> skip" skip  amd "" "" "" "gfx1201"
case_ "AMD, gfx from clinfo only (no ROCMINFO) -> ok" ok    amd "gfx1201" "" "" "gfx1201"
case_ "CPU name does not satisfy a GPU pattern"       wrong amd "gfx1200" "" "$R9060" "7800X3D-is-not-a-gpu|gfx1201"
case_ "wrong card, warn -> logged, keeps running"     wrong nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060" "" "$P5090" warn
case_ "wrong card, IMDS down -> logged, keeps running" wrong nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060" "" "$P5090" reallocate 1
case_ "no EXPECT_GPU -> no check at all"              none  nvidia "NVIDIA GeForce RTX 3060" "NVIDIA GeForce RTX 3060" "" ""

if [ "$fails" -gt 0 ]; then echo "$fails case(s) failed"; exit 1; fi
echo "all gpu_class_check cases passed"
