# Pearl (PRL) GPU miner container for SaladCloud — NVIDIA GPUs

Container image for SaladCloud **NVIDIA** GPU classes (RTX 3060 through
RTX 5090) that mines [Pearl](https://pearlchain.live/) (PRL) on the
**pearlhash** proof-of-useful-work algorithm. Sibling of
[pearl-salad](https://github.com/pvandenburg1234-eng/pearl-salad), the AMD /
ROCm image: same miner-probing entrypoint, CUDA base instead of ROCm.

NVIDIA is where pearlhash runs best. Public benchmarks (TH/s): RTX 5090 ~320,
RTX 4090 ~230–290, RTX 5080 ~183, RTX 5070 Ti ~137, RTX 3080 ~105. For
comparison the best AMD card, the RX 9070 XT, does ~71.

It bundles four miners and auto-selects the first one that produces an
accepted share on the node it lands on:

1. [krig-miner](https://github.com/kryptex/krig-miner) — Kryptex's miner,
   CUDA backend, 0% devfee. **Only works with Kryptex's own pool**; it refuses
   every other pool, so the entrypoint skips it unless `POOL` is a
   `kryptex.network` address. **Unverified on Salad as of 2026-09-23.**
2. [SRBMiner-MULTI](https://github.com/doktor83/SRBMiner-Multi) — pearlhash on
   NVIDIA (2% devfee). Big NVIDIA efficiency gains in 3.6.9. **Unverified.**
3. [BzMiner](https://github.com/bzminer/bzminer) — pearl on NVIDIA (2% devfee).
   **Unverified.**
4. [WildRig-Multi](https://github.com/andru-kun/wildrig-multi) — pearlhash,
   0% devfee, but it may go through OpenCL, which NVIDIA does not fully support
   under WSL2 (which is what Salad nodes run). That's why it's last.
   **Unverified.**

Once you see `ACCEPTED SHARE - this miner works on this node` in the logs,
please update the list above with the card and hashrate.

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
| `MINERS` | order to try, default `krig srb bz wildrig`. Pin one with e.g. `MINERS=srb` |
| `NO_SHARE_TIMEOUT` | seconds a miner gets to produce an accepted share before the next is tried (default `600` — Pearl shares are STARK proofs and the first one can be slow on weak cards) |
| `KRIG_EXTRA_ARGS` / `SRB_EXTRA_ARGS` / `BZ_EXTRA_ARGS` / `WILDRIG_EXTRA_ARGS` | optional extra flags per miner |

There is no `ALGO` variable: every miner spells pearlhash differently
(`--coin pearl`, `--algorithm pearlhash`, `-a pearl`, `--algo pearlhash`), so
the entrypoint hardcodes it per miner.

## 4. Verify

Open the container's logs in the Salad portal. You should see:

1. `nvidia-smi` printing the card name, driver version and VRAM.
2. `Probing Kryptex Pearl regions` followed by `Using nearest region`.
3. `=== [krig] starting ...` then, within a few minutes,
   `=== [krig] ACCEPTED SHARE - this miner works on this node ===` (or the
   same for `srb`, `bz` or `wildrig` if earlier miners were skipped).

Then check `https://pool.kryptex.com/prl` with your wallet address to see
hashrate and estimated earnings; compare that to what Salad bills per hour.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `nvidia-smi not found` or `nvidia-smi failed` | The driver wasn't injected. Either the group is on an AMD class (use `pearl-salad`), or `NVIDIA_VISIBLE_DEVICES` / `NVIDIA_DRIVER_CAPABILITIES` were overridden in the env vars. Leave them alone. |
| Instance fails/reallocates with an **empty** log | The base image's `NVIDIA_REQUIRE_CUDA` gate refused the node's driver before the entrypoint ran. This image clears that variable in the Dockerfile; if you rebased onto a stock `nvidia/cuda` image, add `ENV NVIDIA_REQUIRE_CUDA=` back. |
| RTX 50-series node, miner reports no CUDA device / kernel load error | Blackwell needs CUDA 12.8+ kernels. The base is 12.8; krig ships its own `sm_120` kernels. If SRBMiner/BzMiner fail here, pin `MINERS=krig`. |
| `no accepted share after 600s - killing and trying next miner` | That miner can't hash on this node; the entrypoint moves on. Once you see `ACCEPTED SHARE - this miner works`, pin it with `MINERS=<name>` to skip the probing on future reallocations. |
| WildRig: `no OpenCL platforms` / `CL_...` errors | Expected if NVIDIA OpenCL isn't available under WSL2. That's why it's last. |
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
 krig     ok             231.50        9       4      0%         231.50
 srb      ok             240.20       12       4      2%         235.40
 bz       ok             225.00       12       3      2%         220.50
 wildrig  failed              0        0       0      0%           0.00
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
| v0.3.0 | 2026-09-24 | Benchmark image `pearl-salad-nvidia-bench` (same Dockerfile, `bench` stage) and shared `common.sh`. Share detector now understands BzMiner's `shares=N` counter. `NVIDIA_DISABLE_REQUIRE=true` alongside the empty `NVIDIA_REQUIRE_CUDA`. Diagnostics when a miner is dropped. Still unverified on an NVIDIA node. |
| v0.2.0 | 2026-09-23 | Base → CUDA 12.8.1 (Salad's RTX 50-series requirement) with the driver-version gate cleared so older 30/40-series nodes start. Entrypoint hardening as pearl-salad v1.1.0 (bounded log, SIGTERM, restart-after-shares, stricter share detector, timeout 600). BzMiner 100.36. Still unverified on NVIDIA. |
| v0.1.0 | 2026-09-23 | First release. Same entrypoint as pearl-salad v1.0.0; unverified on NVIDIA |

## Files

- `Dockerfile` — image definition (CUDA 12.8 runtime base + krig-miner, SRBMiner, BzMiner, WildRig); two stages, `miner` (production) and `bench`
- `common.sh` — shared by both entrypoints: GPU check, pool region probe, miner commands, share detector, hashrate parser
- `entrypoint.sh` — production: miner selection by accepted shares
- `bench.sh` — benchmark image: hashrate table + `MINERS=` recommendation
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
