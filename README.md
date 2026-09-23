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
   automatically (~5 min) and pushes `ghcr.io/<you>/pearl-salad-nvidia:latest`.
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
| Image | `ghcr.io/<you>/pearl-salad-nvidia:latest` |
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
| `POOL` | `stratum+tcp://prl.kryptex.network:7048` (default; Kryptex, 1% fee, dashboard at `pool.kryptex.com/prl`). Kryptex is the only pool krig-miner will talk to, and 1% pool fee + krig's 0% devfee beats any 0% pool + SRBMiner's 2% devfee. The **region is auto-selected** at startup by TCP latency from the node (`prl prl-us prl-eu prl-br prl-sg prl-hk prl-ru prl-ae`); the log shows the probe results. Set `POOL_AUTO=0` to use `POOL` exactly as given. Alternative: HeroMiners, `stratum+tcp://ca.pearl.herominers.com:1200` (0% fee, PPS+; regions `ca us us2 us3 de es fi fr ru tr hk sg kr au br` are auto-probed the same way; krig is skipped there and SRBMiner takes over). |
| `WORKER` | optional label; Salad's machine id is used if unset |
| `MINERS` | order to try, default `krig srb bz wildrig`. Pin one with e.g. `MINERS=srb` |
| `NO_SHARE_TIMEOUT` | seconds a miner gets to produce an accepted share before the next is tried (default `300`) |
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
| `CUDA driver version is insufficient for CUDA runtime version` | Node's driver is older than 560. Batch nodes get reallocated, so just wait for the next node; or drop the base image to `nvidia/cuda:12.4.1-runtime-ubuntu22.04` (driver ≥ 550). |
| `no accepted share after 300s - killing and trying next miner` | That miner can't hash on this node; the entrypoint moves on. Once you see `ACCEPTED SHARE - this miner works`, pin it with `MINERS=<name>` to skip the probing on future reallocations. |
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

## Files

- `Dockerfile` — image definition (CUDA 12.6 runtime base + krig-miner, SRBMiner, BzMiner, WildRig)
- `entrypoint.sh` — readiness check, pool region probe, miner selection by accepted shares
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
