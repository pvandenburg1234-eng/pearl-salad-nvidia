# Pearl (pearlhash) benchmarks on SaladCloud

Every miner-vs-miner comparison and sustained fleet measurement we have made
with the `pearl-salad` (AMD) and `pearl-salad-nvidia` images, on rented
SaladCloud consumer GPUs mining to Kryptex over TLS. Newest cards last within
each section. Update this file whenever a bench run finishes.

## How the numbers were taken

- **Bench runs** use the `*-bench` images (`bench.sh`): each miner mines for
  `BENCH_SECONDS` (300 s), the first two hashrate samples are dropped as
  warm-up, and the result is the median of the rest, as the miner reports it.
- **Effective TH/s** = reported x (100 - devfee) / 100, the part that pays you.
  Devfees as applied by `bench.sh`: krig 0 %, SRBMiner-MULTI 2 %, BzMiner 2 %,
  WildRig 0 %.
- **Winner rule (since 30 Sep):** highest effective rate wins; the devfee is
  already taken off, so it is not counted twice. Before 30 Sep a miner within
  3 % of the top was a tie won by the lowest devfee, which picked krig over a
  faster SRBMiner on the RTX 5070 Ti (`BENCH_TIE_PCT` restores a margin).
- **Fleet (sustained)** figures are the median of each device's once-a-minute
  readings over days of production mining, then the median across devices.
- Share counts in a 5-minute window are mostly luck (a 50 TH/s card finds about
  1.7 shares in 5 minutes at the pool's 9.01P share difficulty), so the
  hashrate is the reliable part.
- One host per bench run unless stated. Consumer hosts differ a lot (power
  limits set by the owner, cooling, CPU/PCIe), so a single run can sit 10-20 %
  away from the class average.

## Summary: which miner per GPU class

| Salad GPU class | `MINERS=` | Best effective TH/s seen | Basis |
|---|---|---|---|
| RX 9070 XT | `bz` | ~124 (126 reported) | bench + 25-49 hosts sustained |
| RX 9060 XT | `krig` | ~49-52 | bench + 7 hosts sustained |
| RX 7900 XTX | `srb` | ~54 | one host |
| RTX 5090 | `krig` | ~410 | bench + 6 hosts sustained |
| RTX 5080 | `krig` (tie with bz) | ~221 | one host, full 360 W |
| RTX 5070 Ti | `srb` | ~172 | two hosts; full 300 W on 30 Sep (krig 167.7, bz 100.40 168.7) |
| RTX 4080 | `srb` | ~191 (195 reported) | one host, full 320 W |
| RTX 4070 Ti SUPER | `srb` | ~163 (166 reported) | one host, power limit raised to 110 % |
| RTX 3090 | `srb` | ~121 (123 reported) | one host |
| RTX 3080 / 3080 Ti | `srb` | ~112 (114 uncapped) | bench, 4 hosts |
| RTX 4070 | `srb` or `bz` | ~105 | one host |
| RTX 3060 Ti | `srb` | ~64 at 200 W | 2 hosts, production (not benched against the others) |
| RTX 5080 Laptop | `srb` | ~124 on good hosts | bench, 2 hosts + fleet |
| RTX 5070 Ti Laptop | `srb` | ~88 | fleet |

Rough rule so far: **krig** wins on RDNA4's smaller card (9060 XT) and on
every Blackwell desktop card (5090, and on the 0 % devfee tie-break 5080 and
5070 Ti); **SRBMiner** wins on Ampere (3080/3090), Ada (4080, 4070 Ti SUPER)
and the laptops; **BzMiner** wins on the RX 9070 XT. Not yet benched: RTX 4090.

## AMD (`pearl-salad`)

### RX 9070 XT (gfx1201, RDNA 4)

| Date | Miner | Reported TH/s | Notes |
|---|---|---|---|
| 2026-09-24 | **BzMiner 100.36** | **126.0** | 5 shares in 5 min; pool-side 99-149 |
| 2026-09-24 | SRBMiner 3.6.9 | 90.9 | 2 shares |
| 2026-09-24 | krig-miner 1.5.2 | 87.4 | only at 8 GB container RAM; fails at 4 GB (`host A pinned alloc: 2`, page-locked host memory comes out of the container's RAM limit under WSL) |
| 2026-09-25 to 27 | BzMiner (fleet) | median 126.8, IQR 122-129.3 | 25-49 hosts; ~4 % of hosts sit more than 20 % below the median |

Public references at the time: WhatToMine 70, Kryptex device page 98.5. The
miner software has moved well past them.

### RX 9060 XT (gfx1200, RDNA 4)

| Date | Miner | Reported TH/s | Notes |
|---|---|---|---|
| 2026-09-23 | krig-miner 1.5.2 | 51.9 | first verified release |
| 2026-09-24 | **krig-miner 1.5.2** | **49.1** | bench, 5 shares in 5 min |
| 2026-09-24 | SRBMiner 3.6.9 | 42.3 | 1 share |
| 2026-09-24 | BzMiner 100.36 | 34 falling to 29 | 0 shares |
| 2026-09-24 | WildRig 0.51.2 | - | does not hash under ROCm OpenCL (`n/a TH/s`) |
| 2026-09-27 | krig (fleet) | 48.6-51.6 | 7 hosts at **2 vCPU / 8 GB**, no difference from 4 vCPU |

### RX 7900 XTX (gfx1100, RDNA 3)

| Date | Miner | Reported TH/s | Notes |
|---|---|---|---|
| 2026-09-25 | **SRBMiner** | **55.5** | one host |
| 2026-09-25 | BzMiner | 54.2 | same host |
| 2026-09-25 | krig | 50.8 | same host |

## NVIDIA (`pearl-salad-nvidia`)

Salad's NVIDIA hosts have no OpenCL, so WildRig is not in the NVIDIA image;
SRBMiner logs a harmless `CL_UNKNOWN_ERROR` at start and mines through CUDA.

### RTX 5090 (Blackwell, 32 GB)

Bench, 2026-09-27, one host at its full 600 W limit (max SM clock 3090 MHz):

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| SRBMiner-MULTI | 393.6 | 385.7 | 15 |
| BzMiner 100.36 | 410.8 | 402.6 | 10 |
| **krig-miner 1.5.2** | **~410** | **~410** | 16 (0 stale, 0 rejected) |

Sustained on krig afterwards: 412 TH/s at 600 W, 70 °C = **0.687 TH/s per
watt**. krig warns `vram-guard: ... needs 30142 MiB ... downsized` on every
5090 and still reaches full rate. WhatToMine lists 300 TH/s; the measured
card is about 37 % faster.

Production 5090s on krig (2026-09-27), showing how much the host matters:

| Host | Power limit | Temp | Clock | TH/s |
|---|---|---|---|---|
| A | 600 of 600 W | 70 °C | 2452 MHz | 410-412 |
| B | 600 of 600 W | 68-74 °C | 2290-2385 MHz | 383-392 |
| C | 540 of 600 W | 61 °C | 2250-2290 MHz | 374-376 |
| D | 575 of 575 W | 80-82 °C | 2220-2235 MHz | 356-372 |
| E | 460 of 575 W (80 %, owner cap) | 70 °C | 2034 MHz | 341-342 |
| F | 600 of 600 W | 76 °C | 2610-2630 MHz | 333-336 (host bottleneck, likely CPU/PCIe) |
| G | 517 of 575 W, throttling | 89 °C | 1530-1890 MHz | 262 (image reallocated it after 3 readings above 88 °C) |

Of 15 hosts offered at Medium priority in one afternoon, 11 were rejected by the
image's own checks (10 power caps between 66 and 88 % of the default limit,
1 thermal throttle), each within 1-3 minutes of starting. Use
`POWER_CAP_MIN_PCT` (80-90) on 5090 groups.

### RTX 5080 (Blackwell, 16 GB)

Bench, 2026-09-27, one host at its full 360 W limit (max SM clock 3090 MHz):

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| SRBMiner-MULTI | 214.5 | 210.2 | 4 (360 W, 66 °C, 2797 MHz) |
| BzMiner 100.36 | 225.3 | 220.8 | 9 |
| **krig-miner 1.5.2** | ~220.8 | **~220.8** | 4 (0 stale, 0 rejected) |

krig and BzMiner are level after BzMiner's 2 % devfee, so the tie goes to
krig. About 0.61 TH/s per watt. WhatToMine: 195.

### RTX 5070 Ti (Blackwell, 16 GB)

Bench, 2026-09-27, one host capped by its owner to 250 of 300 W (83 %):

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| SRBMiner-MULTI | 166.8 | 163.5 | 6 |
| BzMiner 100.36 | 163.4 | 160.1 | 3 |
| **krig-miner 1.5.2** | ~159.5 | **~159.5** | 3 |

Under the old 3 % tie rule krig won on its 0 % devfee. 159 TH/s at 250 W,
62 °C = 0.64 TH/s per watt. WhatToMine: 165.

Bench, 2026-09-30, host c146f07c at its full 300 W (76 °C), High tier,
`pearl-salad-nvidia-bench:v1.6.3`:

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| **SRBMiner-MULTI 3.7.0** | ~175.6 | **~172.1** | 5 (1 stale) |
| BzMiner 100.40 | 172.1 | 168.7 | 8 |
| krig-miner 1.5.2 | 167.7 | 167.7 | 8 |

SRBMiner is 2.6 % ahead of krig after its devfee - the old tie rule still
picked krig, which is why the rule changed. BzMiner 100.40's "big NVIDIA
optimizations" do not show on this card (+0.6 % over krig, as 100.36).
The bench's own summary table was lost to the bench-image log-shipping bug;
SRBMiner's figure is from its logged readings (175.5-175.8 TH/s).

### RTX 4080 (Ada, 16 GB)

Bench, 2026-09-27, one host at its full 320 W limit (max SM clock 3105 MHz):

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| **SRBMiner-MULTI** | **194.6** | **190.7** | 4 |
| BzMiner 100.36 | 186.0 | 182.3 | 3 |
| krig-miner 1.5.2 | ~183.8 | ~183.8 | 10 (0 stale, 0 rejected) |

krig is 3.6 % behind SRBMiner's effective rate, just outside the tie margin.
WhatToMine: 168; measured about 16 % higher.

### RTX 4070 Ti SUPER (Ada, 16 GB)

Bench, 2026-09-27, one host whose owner raised the limit to 314 of 285 W (110 %):

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| **SRBMiner-MULTI** | **166.2** | **162.9** | 2 |
| BzMiner 100.36 | 156.5 | 153.4 | 5 |
| krig-miner 1.5.2 | ~152.9 | ~152.9 | 1 (host stopped responding 2 min into krig's run) |

WhatToMine: 144. Expect less on a host at the stock 285 W limit.

### RTX 3090 (Ampere, 24 GB)

Bench, 2026-09-27, one host at its full 350 W limit (max SM clock 2100 MHz):

| Miner | Reported TH/s | Effective TH/s | Shares |
|---|---|---|---|
| **SRBMiner-MULTI** | **123.3** | **120.9** | 3 |
| BzMiner 100.36 | 116.5 | 114.2 | 3 |
| krig-miner 1.5.2 | ~97 | ~97 | - |

349 W = 0.35 TH/s per watt. WhatToMine: 130. A first 3090 host could not reach
the Kryptex pool over TLS and reallocated itself before mining.

### RTX 3080 and 3080 Ti (Ampere)

| Date | Card / host | SRBMiner | BzMiner | krig |
|---|---|---|---|---|
| 2026-09-24 | 3080, uncapped, 350 W | **113.8** | 110.5 | 90.8 |
| 2026-09-24 | 3080, capped to 228 W | **91.9** | 88.6 | 67 |
| 2026-09-24 | 3080 Ti, ~220 W (temp target trimmed 350 to 220 W) | **80** | 75.5 | 73 |
| 2026-09-24 | 3080 Ti, capped to 176 W, ~950 MHz | 16-22 (all miners) | | |

Every early Ampere host was power- or temperature-limited; this is why the
NVIDIA image rejects hosts below `POWER_CAP_MIN_PCT` of their default limit.

### RTX 3060 Ti (Ampere, 8 GB)

Production, 2026-09-28, SRBMiner (`MINERS="srb krig bz"`, not benched against
the others: SRBMiner won every Ampere bench), first 10 minutes of mining:

| Host | Power | SRBMiner reported TH/s |
|---|---|---|
| 0c77791a | 200 W of 200 W default | 65.0 |
| 045d95d4 | 199 W | 63.3 |

~64 TH/s at 200 W = 0.32 TH/s per watt (~62.7 effective after the 2 % devfee).
At $0.03/h (Lowest) or $0.047/h (Low) it returns about twice its cost at 22.9
PRL per PH/s-day and $1.56 - the best return per dollar in the fleet.

### RTX 4070 (Ada, 12 GB)

| Date | Host | SRBMiner | BzMiner | krig |
|---|---|---|---|---|
| 2026-09-24 | 180 W, 2385-2550 MHz, not throttled | 107.6 | **107.7** | 98.0 |

### Laptops

| Date | Card | Miner | TH/s | Notes |
|---|---|---|---|---|
| 2026-09-25 | RTX 5080 Laptop | **SRBMiner** 122.6, BzMiner 119.0 | | 150 W, climbed to 86 °C and was trimmed to 140 W; krig failed on this host's TLS-intercepting network |
| 2026-09-25 | RTX 5080 Laptop | **SRBMiner** 126.5, BzMiner 124.0, krig 117.1 | | ~158 W, second host (Europe) |
| 2026-09-25 to 27 | RTX 5080 Laptop (fleet) | SRBMiner | median 99.8, IQR 96-117 | 3-9 hosts; best 129.6 at 174.8 W; ~1.05 TH/s per watt |
| 2026-09-25 to 27 | RTX 5070 Ti Laptop (fleet) | SRBMiner | median 89.1, IQR 86-95 | 3-9 hosts; ~102 W; ~0.87 TH/s per watt |
| 2026-09-25/26 | RTX 5090 Laptop | SRBMiner | 45 | one host held at ~47 W by its power profile |

Laptops settle at ~86 °C by firmware design and report no power limit, so the
image only applies the temperature ceiling (`POWER_TEMP_MAX`, 88 °C) to them.
