# alpha-miner

GPU miner for the **Pearl (PRL)** network. Mines via AlphaPool's stratum endpoint.

> Binary distribution by permission of the author. Source remains private.

## Hardware support

NVIDIA only. CUDA driver **545+** required.

| Architecture | Generation | Examples |
|---|---|---|
| Volta (sm_70) | data-center | V100, CMP 100-210, CMP 90HX |
| Ampere (sm_86) | RTX 30-series, A-series | 3060 Ti, 3070, 3080, 3090, A4000 |
| Ada (sm_89) | RTX 40-series | 4070, 4080, 4080 SUPER, 4090 |
| Blackwell (sm_120) | RTX 50-series | 5060 Ti, 5070, 5070 Ti, 5080, 5090 |

The miner auto-detects GPU architecture. Override with `--force-backend` if needed.

## Quick start (Linux)

```bash
# 1. download
curl -L -o alpha-miner https://github.com/AlphaMine-Tech/alpha-miner/releases/latest/download/alpha-miner
chmod +x alpha-miner

# 2. verify checksum
curl -L https://github.com/AlphaMine-Tech/alpha-miner/releases/latest/download/SHA256SUMS \
  | sha256sum -c

# 3. mine
./alpha-miner \
  --pool stratum+tcp://15.204.220.54:5566 \
  --address prl1qYOURPEARLADDRESS \
  --worker myrig
```

Pool ports on `pearl.alphapool.tech` (or direct IP `15.204.220.54`):
- `:5566` — PPLNS (default, recommended)
- `:5567` — SOLO

## Common options

| Flag | Purpose |
|---|---|
| `--pool HOST:PORT` | Pool endpoint (or `stratum+tcp://HOST:PORT`) |
| `--address PRL1...` | Your Pearl payout address (required) |
| `--worker NAME` | Worker label, appended to address as `ADDRESS.WORKER` |
| `--password 'x;d=N'` | Static difficulty override; useful for multi-rig setups |
| `--devices 0,1,2` | Mine on specific CUDA devices |
| `--list-devices` | Print available GPUs and exit |
| `--force-backend volta\|ampere\|ada\|blackwell` | Override auto-detect |
| `--status-interval N` | Print status every N attempts (default off) |
| `--debug-logs` | Verbose diagnostic output |

Full flag list: `./alpha-miner help`

## Static difficulty (recommended for multi-GPU / HiveOS)

Vardiff takes 5–7 min to ratchet to the right value on high-end cards. For consistent share submission, pin difficulty in the password field:

```bash
./alpha-miner --pool 15.204.220.54:5566 --address PRL1... --worker myrig \
  --password 'x;d=65536'
```

Recommended starting values:
| GPU class | `d=` |
|---|---|
| 3060 Ti / 3070 | 16384 |
| 3080 / 3090 / 4070 | 32768 |
| 4080 / 4090 / 5080 | 65536 |
| H100 / multi-GPU rig | 131072+ |

## Performance reference

Single GPU, default PPLNS settings:

| GPU | TH/s |
|---|---|
| RTX 3060 Ti | 40–50 |
| RTX 3070 | 50–60 |
| RTX 3090 | ~90 |
| RTX 4090 | 150–160 |
| RTX 5080 | ~105 |
| CMP 100-210 (Volta) | ~70 |

## Multi-GPU

One process drives all GPUs by default. To pin to specific cards:

```bash
./alpha-miner --pool 15.204.220.54:5566 --address PRL1... \
  --worker rig1 --devices 0,1,2,3
```

For per-GPU worker naming on the pool, run one process per GPU and give each a unique `--worker` suffix.

## Systemd service (Linux)

```ini
# /etc/systemd/system/alpha-miner.service
[Unit]
Description=alpha-miner (Pearl PRL GPU miner)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/alpha-miner --pool 15.204.220.54:5566 --address PRL1... --worker mybox --password 'x;d=32768'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo install -m 755 alpha-miner /usr/local/bin/
sudo systemctl daemon-reload
sudo systemctl enable --now alpha-miner
sudo journalctl -u alpha-miner -f
```

## HiveOS

A Custom Miner package is available at:

```
https://github.com/AlphaMine-Tech/alpha-miner/releases/latest/download/alpha-miner-hiveos.tar.gz
```

Install via HiveOS web → Flight Sheet → Add Miner → Custom → Installation URL.

## Troubleshooting

**`libcuda.so.1: cannot open shared object file`**
NVIDIA driver not installed or driver version too old. Install/upgrade to driver 545+.

**`no kernel image is available for execution on the device`**
GPU architecture not supported by this binary build. Try `--force-backend volta` if you're on V100/CMP series.

**Vardiff stuck low**
Set static difficulty: add `--password 'x;d=32768'` (or higher for fast GPUs). See the table above.

**Shares rejected `stale: chain advanced`**
Normal — pool moved to a new block; your in-flight work doesn't count. <1% rejection rate is healthy.

## Support

- Pool stats: <https://pearl.alphapool.tech>
- Discord: link in pool footer
- Issues with this binary: open a GitHub issue

## License

Binary redistribution permitted via this repository. Source is not public. All rights reserved by the author.
