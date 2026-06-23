# alpha-miner — HiveOS Wrapper Fork

> **Fork of [AlphaMine-Tech/alpha-miner](https://github.com/AlphaMine-Tech/alpha-miner)**
> by [nostalgia-mining](https://github.com/nostalgia-mining)

GPU miner for the **Pearl (PRL)** network via [AlphaPool](https://pearl.alphapool.tech). NVIDIA only, CUDA driver **545+**, **0% dev fee**.

This fork adds an enhanced HiveOS wrapper with:

- ✅ `--gpu` alias for `--devices` — use either flag to select GPUs
- ✅ Pool URL driven entirely by the HiveOS **Pool URL** field — no hardcoded endpoints
- ✅ Difficulty driven entirely by the HiveOS **Password** field — set whatever `x;d=N` you want
- ✅ On-screen stats table (`alpha-stats.sh`) — per-GPU hashrate, watt, temp, fan, clock, shares
- ✅ Multi-pool failover via the supervisor (comma-separate pools in the Pool URL field)
- ✅ No donation feature

---

## HiveOS Flight Sheet

| Field | Value |
|---|---|
| Installation URL | `https://github.com/nostalgia-mining/alpha-miner/releases/download/v1.8.3-hiveos/alpha-V1.8.3-hiveos-wrapper.tar.gz` |
| Miner name | `alpha` |
| Hash algorithm | `pearlhash` |
| Wallet template | `%WAL%.%WORKER_NAME%` |
| Pool URL | `stratum+tcp://us1.alphapool.tech:5566` *(or any region, comma-separate for failover)* |
| Password | `x;d=524288` *(or any difficulty value you prefer)* |

### Extra config arguments (all optional)

| Argument | Description |
|---|---|
| `--gpu 0,1` | Select GPUs by CUDA index (alias for `--devices`) |
| `--devices 0,1` | Native alpha-miner GPU selection — same effect as `--gpu` |
| `--nostats` | Disable the on-screen stats helper |
| `--force-backend ada` | Override GPU arch auto-detection |
| `FAILOVER_GRACE_SEC=120` | Seconds before failover check begins (default 120) |
| `FAILOVER_DEAD_SEC=240` | Seconds with no share before pool is declared dead (default 240) |
| `FAILOVER_RETURN_SEC=1800` | Seconds before retrying primary pool (default 1800) |
| `HSTATS_RAW_LINES=6000` | Log lines scanned for stats (default 6000) |

> **Note on `--gpu` vs `--devices`:** Both flags accept the same comma-separated CUDA indices.  
> `--gpu` is a wrapper alias that gets translated to `--devices` before being passed to the binary.  
> You can use either — they are interchangeable.

> **Note on Password / difficulty:** The HiveOS Password field is passed directly to the miner as `--password`.  
> Set it to `x;d=262144`, `x;d=524288`, or any value you prefer. Leave it empty to use vardiff.

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
alpha/
├── alpha                  ← miner binary (not in repo — downloaded via Installation URL)
├── h-manifest.conf        ← miner name, version, paths, API port
├── h-config.sh            ← flight-sheet → miner.conf translation
├── h-run.sh               ← GPU validation, stats helper launch, → supervisor
├── h-stats.sh             ← HiveOS dashboard JSON (kH/s per GPU, shares, temp/fan)
├── alpha-supervise.sh     ← multi-pool failover supervisor (long-lived process)
├── alpha-stats.sh         ← on-screen stats table (printed every 3 min)
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
