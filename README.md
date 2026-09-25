# Pearl (PRL) GPU miner container for SaladCloud — NVIDIA GPUs

Container image for SaladCloud **NVIDIA** GPU classes (RTX 3060 through
RTX 5090) that mines [Pearl](https://pearlchain.live/) (PRL) on the
**pearlhash** proof-of-useful-work algorithm. Sibling of
[pearl-salad](https://github.com/pvandenburg1234-eng/pearl-salad), the AMD /
ROCm image: same miner-probing entrypoint, CUDA base instead of ROCm.

NVIDIA is where pearlhash runs best. Public benchmarks (TH/s): RTX 5090 ~320,
RTX 4090 ~230–290, RTX 5080 ~183, RTX 5070 Ti ~137, RTX 3080 ~105. For
comparison the best AMD card, the RX 9070 XT, does ~71.

It bundles three miners and auto-selects the first one that produces an
accepted share on the node it lands on. The default order is `srb bz krig`,
the measured ranking on two Salad Ampere hosts (see the table below):

1. [krig-miner](https://github.com/kryptex/krig-miner) — Kryptex's miner,
   CUDA backend, 0% devfee. **Only works with Kryptex's own pool**; it refuses
   every other pool, so the entrypoint skips it unless `POOL` is a
   `kryptex.network` address. **Verified on a Salad RTX 3080 Ti 2026-09-24**
   (16.2 TH/s on a host power-capped to 176 W; see the table below).
2. [SRBMiner-MULTI](https://github.com/doktor83/SRBMiner-Multi) — pearlhash on
   NVIDIA (2% devfee). Big NVIDIA efficiency gains in 3.6.9. **Verified on a
   Salad RTX 3080 Ti 2026-09-24**: 22.0 TH/s and the first accepted share on
   the same power-capped host. Uses CUDA directly; its OpenCL probe logs
   `CL_UNKNOWN_ERROR`, which is harmless.
3. [BzMiner](https://github.com/bzminer/bzminer) — pearl on NVIDIA (2% devfee).
   **Verified on a Salad RTX 3080 Ti 2026-09-24**: 20.8 TH/s on the same
   power-capped host, `ampere-sm86-direct` profile. Its device table is the
   only place any miner shows the card's clocks and power under Salad.
WildRig-Multi is **not included** in this image (it is in the AMD sibling).
It is OpenCL-only, with no CUDA path, and NVIDIA's WSL driver ships no OpenCL:
`clinfo` lists zero platforms on Salad NVIDIA nodes, SRBMiner and BzMiner both
log the missing platform before falling back to CUDA, and NVIDIA's CUDA-on-WSL
guide lists OpenCL as not supported. Three Salad hosts, zero hashes, idle
power draw. Removed in v1.4.0.

Once you see `ACCEPTED SHARE - this miner works on this node` in the logs,
please update the list above with the card and hashrate.

| Card (Salad class) | Miner | Rate | Notes | Date |
|---|---|---|---|---|
| RTX 3080 Ti | SRBMiner 3.6.9 | 22.0 TH/s, 1 share in 5 min | host power-capped: 176 W, core 915–990 MHz (card reports 1755 MHz nominal), fan 64%, Ryzen 5 2600 host | 2026-09-24 |
| RTX 3080 Ti | BzMiner 100.36 | 20.8 TH/s, 0 shares | same host | 2026-09-24 |
| RTX 3080 Ti | krig 1.5.2 | 16.2 TH/s, 0 shares | same host; `pattern=H100 (shape rtx-3080)` | 2026-09-24 |
| RTX 3080 Ti | WildRig 0.51.2 | none | no OpenCL under WSL2 | 2026-09-24 |
| RTX 3080 | krig 1.5.2 | 67 TH/s, 0.295 TH/W | production node; host capped at 228 W (~71% of 320 W), core 1155–1200 MHz, fan 56% | 2026-09-24 |
| RTX 3080 | SRBMiner 3.6.9 | **92 TH/s**, 0.404 TH/W | same node and cap; core 1380 MHz. 37% faster than krig on Ampere. | 2026-09-24 |
| RTX 3080 | BzMiner 100.36 | 88.6 TH/s, 0.390 TH/W | same node and cap; core 1350 MHz, 3 shares. 3.6% behind SRBMiner at the same devfee. | 2026-09-24 |
| RTX 3080 Ti (2nd host) | krig 1.5.2 | 88.6 falling to 73 TH/s | slim v1.2.0 bench. Host has a ~70 °C temperature target: the power limit stepped 350 → 308 → 242 → 220 W in the first two minutes under load. Passed the cold startup check; this is what the periodic check (v1.3.0) is for. | 2026-09-24 |
| RTX 3080 Ti (2nd host) | SRBMiner 3.6.9 | 80 TH/s at 219 W | same host, settled at the temperature target. Still ahead of krig. | 2026-09-24 |
| RTX 3080 Ti (2nd host) | BzMiner 100.36 | 75.5 TH/s at 223 W | same host; core 930 MHz. Same ordering as the 3080: SRBMiner > BzMiner > krig on Ampere. | 2026-09-24 |
| RTX 3080 (uncapped host) | SRBMiner 3.6.9 | **113.8 TH/s** at 349.5 W | first full-power Ampere host: core 1680 MHz, 77 °C, fan 58%. Above the ~105 public figure. At $0.06/h Lowest that is ~2.5x return, ahead of the 9070 XT; at $0.087/h Low it is ~1.7x. | 2026-09-24 |
| RTX 3080 (same uncapped host, bench) | BzMiner 100.36 | 110.5 TH/s at ~347 W | core 1650 MHz, 0.318 TH/W. 3% behind SRBMiner in the same bench run, the same gap as on the capped hosts. 1 of 4 NVIDIA hosts uncapped so far. | 2026-09-24 |
| RTX 3080 (same uncapped host, bench) | krig 1.5.2 | 90.8 TH/s at 349 W | core 1560 MHz, 0.260 TH/W, 78 °C. At the same power krig holds 120 MHz less clock than SRBMiner and does 20% less work per watt; its 0% devfee doesn't close a 23% gap. Full-power Ampere order confirmed: srb > bz > krig. | 2026-09-24 |

| RTX 4070 (clean host, bench) | SRBMiner 3.6.9 | 107.6 TH/s at 180 W | core 2385 MHz, 68 °C, fan 32%, 0.60 TH/W. First Ada card: runs at full boost well under its 200 W limit, so owners have little reason to cap it. Middle East host (Kryptex UAE, 21 ms). | 2026-09-24 |
| RTX 4070 (same host, bench) | BzMiner 100.36 | 107.7 TH/s at 180 W | core 2550 MHz, 71 °C, 3 shares in 3 min. Dead heat with SRBMiner on Ada; the 3% Ampere gap does not carry over. | 2026-09-24 |
| RTX 4070 (same host, bench) | krig 1.5.2 | 98.0 TH/s at 172 W | core 2550 MHz, 70 °C, 0.57 TH/W. 91% of the leaders on Ada (80% on Ampere); its 0% devfee still doesn't cover the gap. | 2026-09-24 |

| RTX 5080 Laptop (bench, Low tier) | SRBMiner 3.6.9 | 122.6 TH/s at 150 W | 0.82 TH/W, the best efficiency of any card so far. Core 2050–2080 MHz. Temperature climbed 75 → 82 → 86 °C over the 5-min window at full 150 W. Reported power limit is `[N/A]` (default 80 W shown) - see `POWER_TEMP_MAX`. | 2026-09-25 |
| RTX 5080 Laptop (same host) | BzMiner 100.36 | 119.0 TH/s | `blackwell-sm120-compact` profile, 3 shares. Laptop firmware trimmed it to 140 W / 1985 MHz at 86 °C by minute four. First Blackwell run: the CUDA 12.8 base works. | 2026-09-25 |
| RTX 5080 Laptop (same host) | krig 1.5.2 | no result | refused the pool as "not the official Kryptex PRL pool" on the global endpoint: this host's network intercepts TLS (the region probe read 1–4 ms to every region worldwide; real latency 500 ms). Network, not the card. | 2026-09-25 |
| RTX 5080 Laptop (2nd host, bench) | SRBMiner 3.6.9 | 126.5 TH/s at 158 W | opened at 175 W / 2235 MHz / 85 °C, then the laptop's firmware settled it at ~158 W / 2115 MHz / 86 °C and held there for 15 min with a flat hashrate. **86 °C is this class's steady state, not a fault.** Europe host, 47 ms. | 2026-09-25 |
| RTX 5080 Laptop (2nd host) | BzMiner 100.36 | 124.0 TH/s at 156–162 W | 86 °C throughout, 1 share in 5 min. | 2026-09-25 |
| RTX 5080 Laptop (2nd host) | krig 1.5.2 | 117.1 TH/s at 155 W | 4 shares; 93% of SRBMiner, 6% behind after devfee. Confirms the first host's krig failure was its network, not Blackwell. | 2026-09-25 |

The percentage printed just before the clock in krig's and SRBMiner's stats
lines is **fan speed**, not GPU utilization (SRBMiner's table header labels
that column Fan).

Per-class picks so far (see the AMD sibling for RDNA4):

| Salad GPU class | `MINERS=` | Why |
|---|---|---|
| RTX 3080 / 3080 Ti | `srb` | 113.8 vs BzMiner 110.5 vs krig 90.8 on an uncapped 3080, all three in one bench run; same order on two capped hosts. |
| RTX 4070 (and likely other Ada) | `srb` | 107.6 vs BzMiner 107.7 (tie) vs krig 98.0 on one clean host. Either of the first two is fine. |
| RTX 5080 Laptop | `srb` | 122–126 TH/s on two hosts (BzMiner 119–124, krig 117). Runs at 86 °C by design, ~150–160 W. At $0.08 Lowest that is ~2.0x, level with the 9070 XT on net dollars; the class had spare machines on the demand monitor. |
| others | run the bench | |

That 3080 Ti node was a bad sample: a 3080 Ti at full clocks benchmarks around
116 TH/s. All three CUDA miners agreed on ~20, and the telemetry (only visible
in krig's and BzMiner's stats lines on NVIDIA) shows why: the host had the
card power-limited to half its TDP. Bench a class on two or three nodes before
concluding anything about it. Salad NVIDIA hosts show their clocks and watts;
AMD hosts don't.

**Read the economics note in `Dockerfile` first.** Renting GPUs to mine is usually
a net loss, and Pearl's difficulty has climbed steeply since its April 2026
launch. Test with one replica for 24 h before scaling.

## 1. Get the image built (no Docker needed)

1. Push this folder to a **public** GitHub repository (this one is
   `pearl-salad-nvidia`).
2. On GitHub open the **Actions** tab — the `build-and-push` workflow runs
   automatically (~5 min). A push to `main` updates
   `ghcr.io/<you>/pearl-salad-nvidia:latest`; a git tag `vX.Y.Z` publishes
   `ghcr.io/<you>/pearl-salad-nvidia:vX.Y.Z` (see **Releases** below).
3. Make the package public: your GitHub profile → **Packages** →
   `pearl-salad-nvidia` → **Package settings** → **Change visibility** → Public.
   SaladCloud can only pull public images (or you'd have to configure registry
   credentials in the container group).

## 2. Get a Pearl wallet address

Use the official desktop wallet from
[pearl-research-labs/pearl releases](https://github.com/pearl-research-labs/pearl/releases),
or the community browser extension at [pearlchain.live/wallet](https://pearlchain.live/wallet).
Pearl mainnet addresses are bech32m and **always start with `prl1p`**. The
entrypoint warns if `WALLET` doesn't start with `prl1`. Don't mine to an
exchange deposit address.

## 3. Deploy on SaladCloud

Portal → **Container Groups → Deploy**:

| Setting | Value |
|---|---|
| Image | `ghcr.io/<you>/pearl-salad-nvidia:v0.1.0` — pin a release tag, not `:latest`, so a Batch reallocation can't pull an untested build |
| Replicas | `1` for testing |
| GPU | an **NVIDIA** class. RTX 40 / 50 series give the best TH/s per dollar. Don't put AMD classes in the same group; use `pearl-salad` for those. |
| vCPU / RAM | 2 vCPU / 4 GB |
| Storage | smallest |
| Priority | Batch |
| Command | *(leave empty)* |
| Gateway / health probes | none / off |

Environment variables:

| Name | Value |
|---|---|
| `WALLET` | your Pearl address (`prl1p…`) — **required** |
| `POOL` | `stratum+ssl://prl.kryptex.network:8048` (default; Kryptex, 1% fee, dashboard at `pool.kryptex.com/prl`). TLS on 8048 because krig-miner refuses plain TCP; the other miners get `--tls` / `stratum+ssl://` from the same URL. If you set the plain port 7048, krig is silently given 8048. Kryptex is the only pool krig-miner will talk to, and 1% pool fee + krig's 0% devfee beats any 0% pool + SRBMiner's 2% devfee. The **region is auto-selected** at startup by TCP latency from the node (`prl prl-us prl-eu prl-br prl-sg prl-hk prl-ru prl-ae`); the log shows the probe results. Set `POOL_AUTO=0` to use `POOL` exactly as given. Alternative: HeroMiners, `stratum+tcp://ca.pearl.herominers.com:1200` (0% fee, PPS+; regions `ca us us2 us3 de es fi fr ru tr hk sg kr au br` are auto-probed the same way; krig is skipped there and SRBMiner takes over). |
| `WORKER` | optional label; Salad's machine id is used if unset |
| `MINERS` | order to try, default `srb bz krig` (the measured Ampere ranking). Pin one with e.g. `MINERS=srb` |
| `NO_SHARE_TIMEOUT` | seconds a miner gets to produce an accepted share before the next is tried (default `600` — Pearl shares are STARK proofs and the first one can be slow on weak cards) |
| `KRIG_EXTRA_ARGS` / `SRB_EXTRA_ARGS` / `BZ_EXTRA_ARGS` / `WILDRIG_EXTRA_ARGS` | optional extra flags per miner |
| `POWER_CAP_MIN_PCT` | `70`. At startup the entrypoint reads the card's current power limit and its default from `nvidia-smi`. Below this percentage the host has power-capped the card (a 3080 Ti at 176 W of 350 W hashed ~20 TH/s instead of ~116) and the replica is handed back to Salad for a different node. Salad excludes a rejected node from the group for a while, so keep this loose. |
| `POWER_CAP_ACTION` | `reallocate` (call Salad's metadata service, wait to be stopped) or `warn` (log it and mine anyway). Off Salad the service doesn't exist and it always just warns. |
| `POWER_CHECK_INTERVAL` | `60`. While a miner runs, re-read the power limit, draw, temperature and the driver's thermal-slowdown flags this often. Catches hosts whose tuning software trims the limit after the card warms up (a 3080 Ti went 350 → 308 → 242 → 220 W in two minutes under a 70 °C target), which the one-shot startup check on a cold card can't see. `0` disables. |
| `POWER_CAP_GRACE` | `3`. Consecutive bad readings (limit below `POWER_CAP_MIN_PCT`, thermal slowdown active, or temperature at/above `POWER_TEMP_MAX`) before the miner is stopped and the replica handed back. Three minutes by default, so a momentary dip costs nothing. |
| `POWER_TEMP_MAX` | `88` °C. Temperature ceiling for the periodic check, a fallback for hosts whose driver reports the slowdown flags as `[N/A]`. Laptop GPUs report no power limit at all (`[N/A]`), so on them the thermal checks are the whole protection; NVIDIA laptop GPUs start pulling clocks at about 87 °C. `0` disables. |

There is no `ALGO` variable: every miner spells pearlhash differently
(`--coin pearl`, `--algorithm pearlhash`, `-a pearl`, `--algo pearlhash`), so
the entrypoint hardcodes it per miner.

## 4. Verify

Open the container's logs in the Salad portal. You should see:

1. `nvidia-smi` printing the card name, driver version and VRAM.
2. `Probing Kryptex Pearl regions` followed by `Using nearest region`.
3. `NVIDIA power limit: ... W of ... W default (..%)`. If the host is capped,
   the next lines are `HOST IS POWER-CAPPED` and the reallocation request;
   the replacement instance is the one to read.
4. `=== [srb] starting ...` then, within a few minutes,
   `=== [srb] ACCEPTED SHARE - this miner works on this node ===` (or the
   same for `bz` or `krig` if earlier miners were skipped).

Then check `https://pool.kryptex.com/prl` with your wallet address to see
hashrate and estimated earnings; compare that to what Salad bills per hour.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HOST IS POWER-CAPPED` then `asking Salad to reallocate` | Working as intended: the host runs the card well below its default power limit and would hash at a fraction of the class rate. Salad moves the replica within a minute or two. If a whole class keeps getting rejected, lower `POWER_CAP_MIN_PCT` or set `POWER_CAP_ACTION=warn`. |
| `host check: ... bad reading N/3` then `HOST IS THROTTLING` | The host lowered the power limit or the driver is thermal-throttling after the card warmed up. After `POWER_CAP_GRACE` readings the miner is stopped and Salad moves the replica. The `host check:` lines carry the watts, temperature and clock, so a 70 °C target shows as the limit stepping down while the temperature sits at 70. |
| `nvidia-smi not found` or `nvidia-smi failed` | The driver wasn't injected. Either the group is on an AMD class (use `pearl-salad`), or `NVIDIA_VISIBLE_DEVICES` / `NVIDIA_DRIVER_CAPABILITIES` were overridden in the env vars. Leave them alone. |
| Instance fails/reallocates with an **empty** log | The base image's `NVIDIA_REQUIRE_CUDA` gate refused the node's driver before the entrypoint ran. This image clears that variable in the Dockerfile; if you rebased onto a stock `nvidia/cuda` image, add `ENV NVIDIA_REQUIRE_CUDA=` back. |
| RTX 50-series node, miner reports no CUDA device / kernel load error | Blackwell needs CUDA 12.8+ kernels. The base is 12.8; krig ships its own `sm_120` kernels. If SRBMiner/BzMiner fail here, pin `MINERS=krig`. |
| `no accepted share after 600s - killing and trying next miner` | That miner can't hash on this node; the entrypoint moves on. Once you see `ACCEPTED SHARE - this miner works`, pin it with `MINERS=<name>` to skip the probing on future reallocations. |
| SRBMiner `CL_UNKNOWN_ERROR when getting number of OpenCL platforms`, BzMiner `no OpenCL platforms` | Harmless. NVIDIA's WSL driver has no OpenCL; both miners log it and use CUDA. |
| Shares rejected as stale, pool latency > ~150 ms | Node is far from the pool region. With `POOL_AUTO=1` (default) the entrypoint picks the nearest region of whichever pool is in use; check the `Probing ... regions` lines. |
| `WARNING: Pearl mainnet addresses start with 'prl1p'` | Wrong wallet. Wrapped Pearl (WPRL, an Ethereum `0x…` address) is not a mining payout address. |
| Instance keeps restarting | Batch priority nodes get reallocated; that's normal. Check for `ERROR: set the WALLET` in logs. |

### Not yet wired up

- **MDL merge mining.** HeroMiners lets you earn modelOS (MDL) on top of PRL
  with the same shares. It needs an MDL address passed alongside the PRL one;
  the exact field format wasn't confirmed when this image was made. Add it via
  the `*_EXTRA_ARGS` variables once you have it.
- **Overclocking / power limits.** krig-miner has `--gpu-plimit` and friends,
  but they need NVML write access, which Salad containers don't have.

## Benchmarking the miners (`pearl-salad-nvidia-bench`)

The production image picks the first miner that gets a share, which is a
compatibility test, not a speed test. Miners don't change often, so instead of
benchmarking on every start there is a separate image, built from the same
Dockerfile with the same miner binaries, that you run when you want to know
which miner is fastest on a GPU class (for example after a miner ships a big
update):

```
ghcr.io/<you>/pearl-salad-nvidia-bench:<same tag as production>
```

Deploy it exactly like the production image (one replica, one GPU class, same
`WALLET`). It mines with each miner in turn for `BENCH_SECONDS` (default 300),
parses the hashrate the miner reports, applies that miner's devfee, and prints:

```
 MINER    STATUS   REPORTED TH/s  SAMPLES  SHARES  DEVFEE EFFECTIVE TH/s
 srb      ok              91.94       12       1      2%          90.10
 bz       ok              88.60       10       3      2%          86.83
 krig     ok              67.19       10       0      0%          67.19
 RECOMMENDED for this GPU class:  MINERS=srb
```

(illustrative numbers). Then it keeps mining with the winner until you stop
the group, so the paid node time isn't wasted. Set `MINERS=<winner>` on the
production group for that GPU class. A Salad GPU class pins the card model, so
one run per class is enough until a miner update changes the picture.

Miners within 3% of the top are treated as a tie and the lower devfee wins:
reported rates are only accurate to a few percent, and the pool's 24-hour
worker figure is what actually pays.

| Variable | Default | Meaning |
|---|---|---|
| `BENCH_SECONDS` | `300` | mining window per miner |
| `BENCH_SKIP_SAMPLES` | `2` | warm-up hashrate reports ignored before taking the median |
| `MINERS` | all four | which miners to test, in order |
| `BENCH_THEN` | `mine` | `mine` with the winner, `hold` (idle `BENCH_HOLD` s, then exit) or `exit` (Salad restarts the container, so stop the group once you've read the table) |

The hashrate parser and share counter are verified against the real output of
all four miners from the AMD sibling's Salad runs (krig `Total:` lines,
SRBMiner's colour-coded stats table, BzMiner's `34.07th` unit and `shares=N`
counter, WildRig's `n/a TH/s`). The NVIDIA builds of the same miners are
expected to log the same way. If one shows `failed` with hashrate lines visible
in the log, paste those lines and the parser needs a rule.

## Releases

Images are versioned with git tags. The workflow builds every push to `main`
as `:latest` (for testing), and every tag `vX.Y.Z` as `:vX.Y.Z` and `:vX.Y`.
Release tags never move, so Salad groups pinned to one keep running the exact
build you tested. The entrypoint prints the version as its first log line.

To cut a release after testing `:latest` on one replica:

```bash
git tag -a v1.0.0 -m "what changed" && git push origin v1.0.0
```

Bump the **patch** number for miner version bumps and doc fixes, **minor** for
new behaviour (new miner, new pool, new env var), **major** if an env var
changes meaning or a default pool switches. This image starts at 0.x because
no miner has been verified on a Salad NVIDIA node yet; v1.0.0 is for the
first verified build.

| Version | Date | Notes |
|---|---|---|
| v1.4.1 | 2026-09-25 | Periodic host check works on laptops: when the driver reports no power limit (`[N/A]`, as every laptop GPU does) the thermal-slowdown flags are still evaluated, and a temperature ceiling `POWER_TEMP_MAX` (88 °C) covers drivers that report the flags as `[N/A]` too. Before this the check returned early on laptops and never looked. First 5080 Laptop bench: 122.6 TH/s SRBMiner at 150 W, 86 °C by minute five. |
| v1.4.0 | 2026-09-24 | WildRig removed (OpenCL-only; no OpenCL on Salad NVIDIA nodes, verified four ways). Default `MINERS` is now `srb bz krig`, the measured Ampere ranking, so a group mines on the right miner without setting anything. Bench runs three miners, 15 min instead of 20. |
| v1.3.0 | 2026-09-24 | Periodic host check while mining (`POWER_CHECK_INTERVAL`, `POWER_CAP_GRACE`): re-reads the power limit and thermal-slowdown flags every minute and reallocates after three bad readings. Catches temperature-target hosts that pass the cold startup check and then trim the limit under load. Bench does the same. |
| v1.2.0 | 2026-09-24 | Base image `nvidia/cuda:12.8.1-base` instead of `-runtime`: download drops from 2.3 GB to ~0.4 GB, so reallocations come back faster. The `inspect-miner-deps` workflow showed no miner uses the CUDA toolkit (krig dlopens the driver's `libcuda.so.1`, BzMiner is static, SRBMiner links only libc, WildRig uses apt's OpenCL loader). Same miners, same entrypoint. |
| v1.1.0 | 2026-09-24 | Reject power-capped hosts at startup: reads `nvidia-smi` power limit vs default, and below `POWER_CAP_MIN_PCT` (70) asks Salad's metadata service to reallocate the replica. `POWER_CAP_ACTION=warn` to only log. The 3080 Ti node from the first bench would have been rejected in its first second. |
| v1.0.0 | 2026-09-24 | Same code as v0.3.2, promoted: first verified run on a Salad NVIDIA node (RTX 3080 Ti, driver 616.56, CUDA 12.8 base, driver gate cleared). krig, SRBMiner and BzMiner all hash and SRBMiner's share was accepted; WildRig confirmed dead without OpenCL. |
| v0.3.2 | 2026-09-24 | BzMiner prints its device table every 5 min instead of every 30 s (Salad's group log view caps at 1000 rows); `--no-color`. |
| v0.3.1 | 2026-09-24 | Bench parser: BzMiner summary rows carry `pool hr | miner hr` once shares arrive; take the miner column, not the pool estimate. |
| v0.3.0 | 2026-09-24 | Benchmark image `pearl-salad-nvidia-bench` (same Dockerfile, `bench` stage) and shared `common.sh`. Share detector now understands BzMiner's `shares=N` counter. `NVIDIA_DISABLE_REQUIRE=true` alongside the empty `NVIDIA_REQUIRE_CUDA`. Diagnostics when a miner is dropped. Still unverified on an NVIDIA node. |
| v0.2.0 | 2026-09-23 | Base → CUDA 12.8.1 (Salad's RTX 50-series requirement) with the driver-version gate cleared so older 30/40-series nodes start. Entrypoint hardening as pearl-salad v1.1.0 (bounded log, SIGTERM, restart-after-shares, stricter share detector, timeout 600). BzMiner 100.36. Still unverified on NVIDIA. |
| v0.1.0 | 2026-09-23 | First release. Same entrypoint as pearl-salad v1.0.0; unverified on NVIDIA |

## Files

- `Dockerfile` — image definition (CUDA 12.8 *base* image + SRBMiner, BzMiner, krig-miner, ~0.3 GB); two stages, `miner` (production) and `bench`
- `.github/workflows/inspect.yml` — on-demand: prints what each bundled miner links against and dlopens, for deciding what the image must ship
- `common.sh` — shared by both entrypoints: GPU check, pool region probe, miner commands, share detector, hashrate parser
- `entrypoint.sh` — production: miner selection by accepted shares
- `bench.sh` — benchmark image: hashrate table + `MINERS=` recommendation
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
