#!/usr/bin/env bash
# alpha-miner installer
# usage: curl -sSL https://raw.githubusercontent.com/AlphaMine-Tech/alpha-miner/main/install.sh | bash
set -euo pipefail

REPO="AlphaMine-Tech/alpha-miner"
INSTALL_DIR="${INSTALL_DIR:-$HOME/alpha-miner}"

echo "==> downloading latest alpha-miner from ${REPO}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

curl -fL -o alpha-miner \
  "https://github.com/${REPO}/releases/latest/download/alpha-miner"
curl -fL -o SHA256SUMS \
  "https://github.com/${REPO}/releases/latest/download/SHA256SUMS"

echo "==> verifying checksum"
sha256sum -c SHA256SUMS

chmod +x alpha-miner

echo
echo "==> installed at ${INSTALL_DIR}/alpha-miner"
echo
echo "next step: run it"
echo
echo "  cd ${INSTALL_DIR}"
echo "  ./alpha-miner --pool stratum+tcp://15.204.220.54:5566 \\"
echo "                --address prl1qYOURPEARLADDRESS \\"
echo "                --worker \$(hostname)"
echo
echo "see README at https://github.com/${REPO}"
