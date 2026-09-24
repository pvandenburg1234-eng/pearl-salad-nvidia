# ============================================================================
#  Pearl (PRL, pearlhash) GPU miner for SaladCloud  (NVIDIA GPU classes)
#
#  Sibling of pearl-salad (the AMD / ROCm image). Same share-probing
#  entrypoint, CUDA base instead of ROCm. Pearl is a proof-of-useful-work
#  chain: every share is an int8 matrix-multiply plus a STARK proof, so
#  hashrates read in TH/s and shares are heavy. NVIDIA is where pearlhash
#  runs best (RTX 4090 ~230-290 TH/s, RTX 5090 ~320 TH/s).
#
#  Ships FOUR miners and lets the entrypoint pick the first one that actually
#  produces accepted shares on the node it lands on:
#    1. krig-miner     (Kryptex; CUDA backend, 0% devfee)
#    2. SRBMiner-MULTI (pearlhash on NVIDIA, 2% devfee)
#    3. BzMiner        (pearl on NVIDIA, 2% devfee)
#    4. WildRig-Multi  (pearlhash, 0% devfee; NVIDIA path may go through
#                       OpenCL, which NVIDIA does not fully support under
#                       WSL - so it is last)
#
#  How NVIDIA GPUs work on SaladCloud:
#    * Salad nodes are Windows PCs; containers run under WSL2 with the NVIDIA
#      container toolkit. The host injects the driver (libcuda.so.1,
#      libnvidia-ml.so.1, nvidia-smi) - the image must NOT ship a driver.
#    * The image must be a CUDA image. This one is nvidia/cuda 12.8 "base"
#      (Salad requires CUDA 12.8 for RTX 50-series / Blackwell), with the
#      base image's driver-version gate (NVIDIA_REQUIRE_CUDA) cleared so
#      older-driver 30/40-series nodes are not refused at container start.
#      The miners bring their own kernels and only need libcuda from the
#      driver, so no CUDA toolkit is shipped (~0.4 GB download, not 2.3).
#    * NVIDIA_VISIBLE_DEVICES=all and NVIDIA_DRIVER_CAPABILITIES=compute,utility
#      come from the base image; they are what tells the toolkit to inject
#      the driver. Don't unset them.
#    * `nvidia-smi` is the readiness check; the entrypoint runs it first.
#    * Never mix NVIDIA and AMD classes in one container group.
#
#  ---- BUILD & PUSH ---------------------------------------------------------
#  No Docker locally? Push this folder to a GitHub repo - the included
#  .github/workflows/build.yml builds and pushes ghcr.io/<you>/pearl-salad-nvidia
#  automatically (see README.md).  With Docker:
#    docker build -t YOURUSER/pearl-salad-nvidia:latest .
#    docker push  YOURUSER/pearl-salad-nvidia:latest
#
#  ---- SaladCloud container-group settings ----------------------------------
#    Image Name : ghcr.io/<you>/pearl-salad-nvidia:latest   (must be PUBLIC)
#    Replicas   : 1   (for testing)
#    GPU        : an NVIDIA class (RTX 3060 .. RTX 5090). Do NOT mix with AMD.
#    vCPU / RAM : 2 vCPU / 4 GB
#    Storage    : minimum
#    Priority   : Batch (cheapest, interruptible - fine for mining)
#    Command    : leave EMPTY (the ENTRYPOINT below runs the miner)
#    Gateway    : none        Health probe : OFF
#    Environment Variables:
#      WALLET = <your Pearl address, prl1p...>   (REQUIRED)
#      POOL   = <pool host:port>                 (see options below)
#      MINERS = optional; default "krig srb bz wildrig"
#      WORKER = optional; Salad's machine id is used automatically if unset
#
#  ---- POOL options ---------------------------------------------------------
#    Pearl - Kryptex, 1% fee, DEFAULT. The only pool krig-miner (0% devfee)
#    will talk to. Region auto-selected by latency at startup (prl prl-us
#    prl-eu prl-br prl-sg prl-hk prl-ru prl-ae; POOL_AUTO=0 to pin). TLS port
#    8048 because krig-miner refuses plain TCP (7048 works for the others):
#      POOL   = stratum+ssl://prl.kryptex.network:8048
#    Pearl - HeroMiners, 0% fee (alternative; krig is skipped, SRBMiner 2%
#    devfee takes over; regions ca us us2 us3 de es fi fr ru tr hk sg kr au br):
#      POOL   = stratum+tcp://ca.pearl.herominers.com:1200
#
#  ---- HONEST NOTE ON ECONOMICS ---------------------------------------------
#    On public SaladCloud rental prices, renting a GPU to mine generally LOSES
#    money (rent >= coin yield). Pearl's difficulty has been climbing fast since
#    its April 2026 launch. Treat this as a test. Deploy ONE replica for 24h
#    and compare the pool's estimated daily earnings to the all-in $/hr Salad
#    bills you BEFORE scaling replicas.
# ============================================================================

# CUDA "base" image: the NVIDIA env vars that make the container toolkit inject
# the host driver (libcuda.so.1, nvidia-smi), and nothing else. We inspected
# the miners (see .github/workflows/inspect.yml): krig dlopens libcuda.so.1
# straight from the driver, BzMiner is fully static, SRBMiner links only libc,
# and WildRig wants an OpenCL loader that apt provides. None of them use the
# CUDA toolkit, so the 2.8 GB "runtime" flavour (cudart, cublas, cufft, ...)
# was dead weight: it took the download from ~0.4 GB to 2.3 GB on every Salad
# reallocation. 12.8 is the first CUDA with Blackwell (sm_120) support, which
# SaladCloud requires for RTX 50-series.
FROM nvidia/cuda:12.8.1-base-ubuntu24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# The nvidia/cuda base sets NVIDIA_REQUIRE_CUDA=cuda>=12.8, which the NVIDIA
# container toolkit enforces at container START: a node whose host driver is
# older than the matching release is refused before the entrypoint even runs,
# with nothing in the Salad log. The miners bring their own CUDA kernels and
# only need libcuda from the driver, and CUDA 12.x runtimes work on any 12.x
# driver (minor-version compatibility), so drop the constraint and let older
# 30/40-series nodes run too.
ENV NVIDIA_REQUIRE_CUDA=
# Belt and braces: the empty string works because libnvidia-container's
# expression evaluator treats an empty predicate as satisfied, but
# NVIDIA_DISABLE_REQUIRE is the documented switch and short-circuits before
# any NVIDIA_REQUIRE_* value is even read.
ENV NVIDIA_DISABLE_REQUIRE=true

# Set by the build workflow to the git tag (v1.2.3) or branch; the entrypoint
# prints it so the Salad log says which image version a node is running.
ARG IMAGE_VERSION=dev
ENV IMAGE_VERSION=${IMAGE_VERSION}

# OpenCL ICD loader + NVIDIA ICD file, for WildRig. The container toolkit
# mounts libnvidia-opencl.so.1 from the host when NVIDIA_DRIVER_CAPABILITIES
# includes "compute"; the ICD file just tells the loader where to look.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget curl ocl-icd-libopencl1 clinfo procps \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/OpenCL/vendors \
    && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

# Each miner tarball lays itself out differently (some have a top-level dir,
# some don't). Extract into a scratch dir, find the binary, and move whatever
# directory contains it to /opt/<name>. That way a version bump can't break
# the build because the archive layout changed.

# --- 1. krig-miner (Kryptex) -------------------------------------------------
ARG KRIG_VERSION=1.5.2
RUN wget -qO /tmp/krig.tgz \
      https://github.com/kryptex/krig-miner/releases/download/v${KRIG_VERSION}/krig-miner-${KRIG_VERSION}-linux-x64.tar.gz \
 && mkdir -p /tmp/krig && tar xzf /tmp/krig.tgz -C /tmp/krig \
 && bin="$(find /tmp/krig -type f -name 'krig-miner*' ! -name '*.txt' ! -name '*.md' | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/krig \
 && ( [ -x /opt/krig/krig-miner ] || mv "/opt/krig/$(basename "$bin")" /opt/krig/krig-miner ) \
 && chmod +x /opt/krig/krig-miner && rm -rf /tmp/krig /tmp/krig.tgz \
 && ls -la /opt/krig

# --- 2. SRBMiner-MULTI ------------------------------------------------------
ARG SRB_VERSION=3.6.9
RUN wget -qO /tmp/srb.tgz \
      https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRB_VERSION}/SRBMiner-Multi-$(echo ${SRB_VERSION} | tr . -)-Linux.tar.gz \
 && mkdir -p /tmp/srb && tar xzf /tmp/srb.tgz -C /tmp/srb \
 && bin="$(find /tmp/srb -type f -name SRBMiner-MULTI | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/srb \
 && chmod +x /opt/srb/SRBMiner-MULTI && rm -rf /tmp/srb /tmp/srb.tgz \
 && ls -la /opt/srb

# --- 3. BzMiner --------------------------------------------------------------
ARG BZ_VERSION=100.36
RUN wget -qO /tmp/bz.tgz \
      https://github.com/bzminer/bzminer/releases/download/v${BZ_VERSION}/bzminer_v${BZ_VERSION}_linux.tar.gz \
 && mkdir -p /tmp/bz && tar xzf /tmp/bz.tgz -C /tmp/bz \
 && bin="$(find /tmp/bz -type f -name bzminer | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/bz \
 && chmod +x /opt/bz/bzminer && rm -rf /tmp/bz /tmp/bz.tgz \
 && ls -la /opt/bz

# --- 4. WildRig-Multi (last resort) ----------------------------------------
ARG WILDRIG_VERSION=0.51.2
RUN wget -qO /tmp/w.tgz \
      https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz \
 && mkdir -p /tmp/w && tar xzf /tmp/w.tgz -C /tmp/w \
 && bin="$(find /tmp/w -type f -name wildrig-multi | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/wildrig \
 && chmod +x /opt/wildrig/wildrig-multi && rm -rf /tmp/w /tmp/w.tgz \
 && ls -la /opt/wildrig

# Runtime defaults - override these in the SaladCloud env vars
ENV POOL=stratum+ssl://prl.kryptex.network:8048 \
    WALLET=REPLACE_WITH_YOUR_WALLET \
    WORKER=salad01 \
    MINERS="krig srb bz wildrig" \
    NO_SHARE_TIMEOUT=600

# Tells common.sh which GPU readiness check and miner flags to use.
ENV MINER_VENDOR=nvidia

COPY common.sh entrypoint.sh bench.sh /
RUN chmod +x /entrypoint.sh /bench.sh

# --- bench image: same miners, different entrypoint ---------------------------
# Published as ghcr.io/<you>/pearl-salad-nvidia-bench. Runs every miner for a
# fixed window and prints a hashrate table + MINERS= recommendation (bench.sh).
FROM base AS bench
ENTRYPOINT ["/bench.sh"]

# --- production image (last stage = default for a plain `docker build`) -------
FROM base AS miner
ENTRYPOINT ["/entrypoint.sh"]
