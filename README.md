# alpha-miner — HiveOS Wrapper Fork

> **Fork of [AlphaMine-Tech/alpha-miner](https://github.com/AlphaMine-Tech/alpha-miner)**
> by [nostalgia-mining](https://github.com/nostalgia-mining)

GPU miner for the **Pearl (PRL)** network via [AlphaPool](https://pearl.alphapool.tech). NVIDIA only, CUDA driver **545+**, **0% dev fee**.

📦 **[Download latest release](https://github.com/nostalgia-mining/alpha-miner/releases)**

This fork adds an enhanced HiveOS wrapper with:

- ✅ `--gpu` alias for `--devices` — use either flag to select GPUs
- ✅ Pool URL driven entirely by the HiveOS **Pool URL** field — no hardcoded endpoints
- ✅ `--diff` to set a static difficulty (comma separated per GPU) - e.g. `--diff 524288,262144,1048576,524288`
- ✅ `--mdl` to enable merged mining with ModelOS (MDL) — e.g. `--mdl YOUR_MDL_ADDRESS`
- ✅ On-screen stats table (`alpha-stats.sh`) — per-GPU hashrate, watt, temp, fan, clock, shares
- ✅ Multi-pool failover via the supervisor (comma-separate pools in the Pool URL field)

---

## HiveOS Flight Sheet

| Field | Value |
|---|---|
| Installation URL | `https://github.com/nostalgia-mining/alpha-miner/releases/download/v1.8.3-hiveos/alpha-wrapper-V1.8.3.tar.gz` |
| Miner name | `alpha-wrapper` |
| Hash algorithm | `pearlhash` |
| Wallet template | `%WAL%.%WORKER_NAME%` |
| Pool URL | `stratum+tcp://%URL%` *(set pool endpoints directly in HiveOS Flight Sheet via Configure pool)* |
| Password | `x` *(leave as `x` — difficulty defaults to 524288; use `--diff` or `--vardiff` in extra config)* |

### Extra config arguments (all optional)

| Argument | Description |
|---|---|
| `--gpu 0,1` | Select GPUs by CUDA index (alias for `--devices`) |
| `--devices 0,1` | Native alpha-miner GPU selection — same effect as `--gpu` |
| `--diff 524288` | Set static difficulty for all GPUs (alias for `x;d=N` in Password field) |
| `--diff 524288,262144` | Per-GPU difficulty (comma-separated, one value per GPU) |
| `--vardiff` | Use pool-controlled variable difficulty (overrides default 524288) |
| `--mdl ADDRESS` | Enable merged mining with ModelOS (MDL). Appends `;mdl=ADDRESS` to password. |
| `--nostats` | Disable the on-screen stats helper |
| `--detail` | Show diff, job ID, and share counter on each share line |
| `--force-backend ada` | Override GPU arch auto-detection |
| `FAILOVER_GRACE_SEC=120` | Seconds before failover check begins (default 120) |
| `FAILOVER_DEAD_SEC=240` | Seconds with no share before pool is declared dead (default 240) |
| `FAILOVER_RETURN_SEC=1800` | Seconds before retrying primary pool (default 1800) |
| `BUFFER_LINES=10000` | Rolling buffer size in lines (default 10000, ~2 min on 12 GPUs) |
| `HSTATS_RAW_LINES=6000` | Log lines scanned for stats (default 2000) |

> **Note on `--gpu` vs `--devices`:** Both flags accept the same comma-separated CUDA indices.  
> `--gpu` is a wrapper alias that gets translated to `--devices` before being passed to the binary.  
> You can use either — they are interchangeable.

> **Note on difficulty:** The wrapper defaults to static difficulty **524288** if no `--diff` is specified and the Password field is empty or `x`. To use pool-controlled variable difficulty (vardiff), add `--vardiff` to Extra config. To set a custom static difficulty, use `--diff N` (e.g., `--diff 262144` or `--diff 524288,262144` for per-GPU values).

> **Note on merged mining (MDL):** To enable merged mining with ModelOS, add `--mdl YOUR_MDL_ADDRESS` to Extra config. This appends `;mdl=ADDRESS` to the password string. Works with `--diff`, `--vardiff`, or the default difficulty. Examples:
> - `--mdl mdl1abc...` → password becomes `x;d=524288;mdl=mdl1abc...`
> - `--diff 262144 --mdl mdl1abc...` → `x;d=262144;mdl=mdl1abc...`
> - `--vardiff --mdl mdl1abc...` → `x;mdl=mdl1abc...`

---

## Pool endpoints (AlphaPool)

**PPLNS = port `5566` · SOLO = port `5567`**

| Region | Host |
|---|---|
| US East | `us1.alphapool.tech` |
| US West | `us2.alphapool.tech` |
| Europe | `eu1.alphapool.tech` |
| Europe 2 | `eu2.alphapool.tech` |
| Russia / Eurasia | `ru1.alphapool.tech` |
| India | `in1.alphapool.tech` |
| Asia (Singapore) | `sg1.alphapool.tech` |

---

## Wrapper file overview

```
alpha-wrapper/
├── alpha                  ← miner binary (not in repo — downloaded via build-hiveos-package.sh)
├── h-manifest.conf        ← miner name, version, paths, API port
├── h-config.sh            ← flight-sheet → miner.conf translation
├── h-run.sh               ← GPU validation, stats helper launch, → supervisor
├── h-stats.sh             ← HiveOS dashboard JSON (kH/s per GPU, shares, temp/fan)
├── alpha-supervise.sh     ← multi-pool failover supervisor (long-lived process)
├── alpha-stats.sh         ← on-screen stats table (printed every 30 seconds)
├── alpha-events.sh        ← real-time event printer (shares, jobs, pool events)
└── miner.conf             ← generated at runtime by h-config.sh
```

---

## Quick start (Linux, no HiveOS)

```bash
curl -L -o alpha-miner https://github.com/AlphaMine-Tech/alpha-miner/releases/latest/download/alpha-miner
chmod +x alpha-miner
./alpha-miner --pool stratum+tcp://us1.alphapool.tech:5566 \
              --address prl1YOUR_ADDRESS \
              --worker rig01 \
              --password 'x;d=524288'
```

---

## Hardware

| Arch | Cards |
|---|---|
| Volta (sm_70) | V100, CMP 100-210 |
| Ampere (sm_86) | RTX 30-series, A-series, CMP HX |
| Ada (sm_89) | RTX 40-series |
| Hopper (sm_90) | H100, H200 |
| Blackwell (sm_120) | RTX 50-series, B100/B200 |

---

## License

Binary redistribution permitted via this repository. Source is not public. All rights reserved by the original author ([AlphaMine-Tech](https://github.com/AlphaMine-Tech)).  
Wrapper scripts in this fork are original work by [nostalgia-mining](https://github.com/nostalgia-mining) and released under MIT.
