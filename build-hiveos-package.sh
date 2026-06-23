#!/usr/bin/env bash
#
# build-hiveos-package.sh
#
# Run this on Linux (Ubuntu / HiveOS rig) to produce the HiveOS-installable
# tarball with correct Unix permissions and LF line endings.
#
# Usage:
#   git clone https://github.com/nostalgia-mining/alpha-miner
#   cd alpha-miner
#   bash build-hiveos-package.sh
#
# Output:
#   alpha-wrapper-V1.8.3.tar.gz  ← attach to a GitHub Release as asset

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER_DIR="$SCRIPT_DIR/alpha-wrapper"
VERSION="1.8.3"
BINARY_FILENAME="alpha-miner"
BINARY_URL="https://github.com/AlphaMine-Tech/alpha-miner/releases/download/v${VERSION}/${BINARY_FILENAME}"
BINARY_DEST="$WRAPPER_DIR/alpha"      # HiveOS expects the binary named 'alpha'
OUTPUT="$SCRIPT_DIR/alpha-wrapper-V${VERSION}.tar.gz"

# Expected SHA256 of the alpha-miner Linux binary (from upstream SHA256SUMS)
EXPECTED_SHA256="927f50f63343bb63b9e6eeed77d2959200e2c1df2022c84f47a117af50475fdb"

echo "================================================"
echo " AlphaMiner PEARL — HiveOS package builder"
echo " Version : $VERSION"
echo " Output  : $OUTPUT"
echo "================================================"
echo ""

# ---- Check dependencies ------------------------------------------------------
for cmd in curl sha256sum dos2unix tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install it first:"
        case "$cmd" in
            dos2unix) echo "  sudo apt-get install -y dos2unix" ;;
            curl)     echo "  sudo apt-get install -y curl" ;;
            *)        echo "  sudo apt-get install -y $cmd" ;;
        esac
        exit 1
    fi
done

# ---- Validate wrapper directory ----------------------------------------------
if [[ ! -d "$WRAPPER_DIR" ]]; then
    echo "ERROR: alpha-wrapper/ not found at $WRAPPER_DIR"
    echo "Make sure you cloned the full repo and are running from its root."
    exit 1
fi

# ---- Download binary ---------------------------------------------------------
if [[ -f "$BINARY_DEST" ]]; then
    echo "Binary already present: $BINARY_DEST  ($(du -sh "$BINARY_DEST" | cut -f1))"
    echo "Skipping download. Delete it and re-run to force a fresh download."
else
    echo "Downloading alpha-miner v${VERSION}..."
    curl -L --fail --progress-bar -o "$BINARY_DEST" "$BINARY_URL"
    echo "Downloaded: $(du -sh "$BINARY_DEST" | cut -f1)"
fi

# ---- Verify binary SHA256 ----------------------------------------------------
echo ""
echo "Verifying binary SHA256..."
ACTUAL_SHA256=$(sha256sum "$BINARY_DEST" | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "ERROR: SHA256 mismatch!"
    echo "  Expected : $EXPECTED_SHA256"
    echo "  Got      : $ACTUAL_SHA256"
    echo "The downloaded binary may be corrupt or tampered. Aborting."
    rm -f "$BINARY_DEST"
    exit 1
fi
echo "SHA256 OK: $ACTUAL_SHA256"

# ---- Safety check — no NOCKminer files --------------------------------------
echo ""
echo "Safety check — scanning for NOCKminer files..."
if find "$WRAPPER_DIR" \( -name "*nockminer*" -o -name "*golden-miner*" \) 2>/dev/null | grep -q .; then
    echo "ERROR: NOCKminer files detected in alpha-wrapper/. Aborting."
    exit 1
fi
echo "Clean."

# ---- Fix CRLF line endings (files may have been edited on Windows) -----------
echo ""
echo "Fixing line endings (CRLF → LF)..."
find "$WRAPPER_DIR" -maxdepth 1 -name "*.sh" -o -name "*.conf" | while read -r f; do
    dos2unix "$f" 2>/dev/null && echo "  fixed: $(basename "$f")"
done
echo "Done."

# ---- Set execute permissions -------------------------------------------------
echo ""
echo "Setting permissions..."
chmod 755 "$BINARY_DEST"
chmod 755 "$WRAPPER_DIR"/*.sh
chmod 644 "$WRAPPER_DIR"/miner.conf
chmod 644 "$WRAPPER_DIR"/h-manifest.conf
echo "  755  alpha (binary)"
echo "  755  *.sh"
echo "  644  miner.conf"
echo "  644  h-manifest.conf"

# ---- Build tarball -----------------------------------------------------------
echo ""
echo "Building tarball..."
cd "$SCRIPT_DIR"

# -p preserves permissions; --owner=0 --group=0 avoids embedding local uid/gid
tar -czpf "$OUTPUT" \
    --owner=0 --group=0 \
    alpha-wrapper/alpha \
    alpha-wrapper/h-manifest.conf \
    alpha-wrapper/h-config.sh \
    alpha-wrapper/h-run.sh \
    alpha-wrapper/h-stats.sh \
    alpha-wrapper/alpha-supervise.sh \
    alpha-wrapper/alpha-stats.sh \
    alpha-wrapper/miner.conf

# ---- Verify ------------------------------------------------------------------
echo ""
echo "=== Package built successfully ==="
echo ""
echo "File : $OUTPUT"
echo "Size : $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "Contents + permissions:"
tar -tzvf "$OUTPUT"

# ---- Checksum of the package itself ------------------------------------------
echo ""
PACKAGE_SHA=$(sha256sum "$OUTPUT" | awk '{print $1}')
echo "Package SHA256: $PACKAGE_SHA"
echo "$PACKAGE_SHA  alpha-wrapper-V${VERSION}.tar.gz" > "$SCRIPT_DIR/alpha-wrapper-V${VERSION}.sha256"
echo "Checksum saved to: alpha-wrapper-V${VERSION}.sha256"

# ---- Next steps --------------------------------------------------------------
echo ""
echo "================================================"
echo " Next steps"
echo "================================================"
echo ""
echo "1. Create a GitHub Release:"
echo "   https://github.com/nostalgia-mining/alpha-miner/releases/new"
echo "   Tag     : v${VERSION}-hiveos"
echo "   Title   : HiveOS wrapper v${VERSION}"
echo ""
echo "2. Attach these files to the release:"
echo "   - $OUTPUT"
echo "   - alpha-wrapper-V${VERSION}.sha256"
echo ""
echo "3. HiveOS Flight Sheet — Installation URL:"
echo "   https://github.com/nostalgia-mining/alpha-miner/releases/download/v${VERSION}-hiveos/alpha-wrapper-V${VERSION}.tar.gz"
echo ""
echo "4. Commit and push the updated scripts if you made any changes:"
echo "   git add -A && git commit -m 'fix: ...' && git push origin main"
echo ""
