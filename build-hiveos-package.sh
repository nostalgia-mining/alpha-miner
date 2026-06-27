#!/usr/bin/env bash
#
# build-hiveos-package.sh
#
# Run this on Linux (Ubuntu / HiveOS rig) to produce the HiveOS-installable
# tarball with correct Unix permissions and LF line endings.
#
# Usage:
#   bash build-hiveos-package.sh              # builds with default version (1.8.3)
#   bash build-hiveos-package.sh 1.8.5        # builds with specified version (auto-detect URL)
#   bash build-hiveos-package.sh 1.8.5 https://pearl.alphapool.tech/downloads/alpha-miner-1.8.5
#                                             # builds with explicit binary URL
#
# Output:
#   alpha-wrapper-V{VERSION}.tar.gz

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER_DIR="$SCRIPT_DIR/alpha-wrapper"
VERSION="${1:-1.8.3}"
BINARY_URL="${2:-}"
BINARY_DEST="$WRAPPER_DIR/alpha"      # HiveOS expects the binary named 'alpha'
OUTPUT="$SCRIPT_DIR/alpha-wrapper-V${VERSION}.tar.gz"

# If no explicit URL, try sources in order
if [[ -z "$BINARY_URL" ]]; then
    # Try GitHub release first, then alphapool.tech
    BINARY_URL_GITHUB="https://github.com/AlphaMine-Tech/alpha-miner/releases/download/v${VERSION}/alpha-miner"
    BINARY_URL_ALPHAPOOL="https://pearl.alphapool.tech/downloads/alpha-miner-${VERSION}"
fi

# Known SHA256 hashes (add new versions here as they become known)
declare -A KNOWN_SHA256=(
    ["1.8.3"]="927f50f63343bb63b9e6eeed77d2959200e2c1df2022c84f47a117af50475fdb"
)

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
    if [[ -n "$BINARY_URL" ]]; then
        echo "Downloading alpha-miner v${VERSION} from: $BINARY_URL"
        curl -L --fail --progress-bar -o "$BINARY_DEST" "$BINARY_URL"
    else
        echo "Trying GitHub release..."
        if curl -L --fail --progress-bar -o "$BINARY_DEST" "$BINARY_URL_GITHUB" 2>/dev/null; then
            echo "Downloaded from GitHub."
        else
            echo "GitHub failed, trying alphapool.tech..."
            curl -L --fail --progress-bar -o "$BINARY_DEST" "$BINARY_URL_ALPHAPOOL"
            echo "Downloaded from alphapool.tech."
        fi
    fi
    echo "Size: $(du -sh "$BINARY_DEST" | cut -f1)"
fi

# ---- Verify binary SHA256 (if known) ----------------------------------------
echo ""
if [[ -n "${KNOWN_SHA256[$VERSION]:-}" ]]; then
    echo "Verifying binary SHA256..."
    ACTUAL_SHA256=$(sha256sum "$BINARY_DEST" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256" != "${KNOWN_SHA256[$VERSION]}" ]]; then
        echo "ERROR: SHA256 mismatch!"
        echo "  Expected : ${KNOWN_SHA256[$VERSION]}"
        echo "  Got      : $ACTUAL_SHA256"
        echo "The downloaded binary may be corrupt or tampered. Aborting."
        rm -f "$BINARY_DEST"
        exit 1
    fi
    echo "SHA256 OK: $ACTUAL_SHA256"
else
    echo "No known SHA256 for v${VERSION} — skipping verification."
    echo "SHA256: $(sha256sum "$BINARY_DEST" | awk '{print $1}')"
fi

# ---- Safety check — no NOCKminer files --------------------------------------
echo ""
echo "Safety check — scanning for NOCKminer files..."
if find "$WRAPPER_DIR" \( -name "*nockminer*" -o -name "*golden-miner*" \) 2>/dev/null | grep -q .; then
    echo "ERROR: NOCKminer files detected in alpha-wrapper/. Aborting."
    exit 1
fi
echo "Clean."

# ---- Fix CRLF line endings in a temp staging directory ----------------------
# We work on copies so the git working tree stays clean (no 'modified' files
# after the build, which would block the next git pull).
echo ""
echo "Staging files with LF line endings..."
STAGE_DIR="$(mktemp -d)"
trap "rm -rf '$STAGE_DIR'" EXIT

cp -r "$WRAPPER_DIR" "$STAGE_DIR/alpha-wrapper"
cp "$BINARY_DEST" "$STAGE_DIR/alpha-wrapper/alpha"

find "$STAGE_DIR/alpha-wrapper" -name "*.sh" -o -name "*.conf" | while read -r f; do
    dos2unix "$f" 2>/dev/null && echo "  fixed: $(basename "$f")"
done
echo "Done."

# ---- Set execute permissions -------------------------------------------------
echo ""
echo "Setting permissions..."
chmod 755 "$STAGE_DIR/alpha-wrapper/alpha"
chmod 755 "$STAGE_DIR/alpha-wrapper"/*.sh
chmod 644 "$STAGE_DIR/alpha-wrapper/miner.conf"
chmod 644 "$STAGE_DIR/alpha-wrapper/h-manifest.conf"
echo "  755  alpha (binary)"
echo "  755  *.sh"
echo "  644  miner.conf"
echo "  644  h-manifest.conf"

# ---- Build tarball -----------------------------------------------------------
echo ""
echo "Building tarball..."
cd "$STAGE_DIR"

# List all files that will be included
WRAPPER_FILES=(
    alpha-wrapper/alpha
    alpha-wrapper/h-manifest.conf
    alpha-wrapper/h-config.sh
    alpha-wrapper/h-run.sh
    alpha-wrapper/h-stats.sh
    alpha-wrapper/alpha-supervise.sh
    alpha-wrapper/alpha-stats.sh
    alpha-wrapper/alpha-events.sh
    alpha-wrapper/miner.conf
)

# Verify every file exists before packaging
echo "Verifying files..."
for f in "${WRAPPER_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: missing file: $f"
        exit 1
    fi
    echo "  ok: $f"
done

# -p preserves permissions; --owner=0 --group=0 avoids embedding local uid/gid
tar -czpf "$OUTPUT" \
    --owner=0 --group=0 \
    "${WRAPPER_FILES[@]}"

cd "$SCRIPT_DIR"

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
echo " GitHub Release"
echo "================================================"
echo ""
echo "Upload the package to GitHub Releases using the API."
echo "You need a GitHub Personal Access Token with 'repo' scope."
echo "(Create one at: https://github.com/settings/tokens)"
echo ""

# Try to load saved token
TOKEN_FILE="$HOME/.alpha-wrapper-gh-token"
GH_TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
    GH_TOKEN=$(cat "$TOKEN_FILE")
    echo "Using saved token from $TOKEN_FILE"
fi

if [[ -z "$GH_TOKEN" ]]; then
    read -rsp "GitHub Token (input hidden): " GH_TOKEN
    echo ""
    if [[ -n "$GH_TOKEN" ]]; then
        read -rp "Save token for future builds? [y/N]: " SAVE_TOKEN
        if [[ "${SAVE_TOKEN,,}" == "y" ]]; then
            echo "$GH_TOKEN" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            echo "Token saved to $TOKEN_FILE"
        fi
    fi
fi

if [[ -z "$GH_TOKEN" ]]; then
    echo "No token provided — skipping GitHub upload."
    echo ""
    echo "Manual steps:"
    echo "  1. Go to: https://github.com/nostalgia-mining/alpha-miner/releases/new"
    echo "  2. Tag: v${VERSION}-hiveos"
    echo "  3. Upload: $OUTPUT"
    echo "  4. Upload: alpha-wrapper-V${VERSION}.sha256"
    echo ""
    exit 0
fi

REPO="nostalgia-mining/alpha-miner"
TAG="v${VERSION}-hiveos"
RELEASE_TITLE="HiveOS wrapper v${VERSION}"
RELEASE_NOTES="HiveOS wrapper v${VERSION} — see README for flight sheet setup."

echo ""
echo "Creating GitHub Release ${TAG}..."

# Check if release already exists
EXISTING=$(curl -s \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" 2>/dev/null \
    | grep '"id"' | head -1 | grep -oE '[0-9]+' || true)

if [[ -n "$EXISTING" ]]; then
    echo "Release ${TAG} already exists (id=${EXISTING}) — will upload assets to it."
    RELEASE_ID="$EXISTING"
else
    # Create the release
    RESPONSE=$(curl -s \
        -H "Authorization: token $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -X POST \
        "https://api.github.com/repos/${REPO}/releases" \
        -d "{
            \"tag_name\": \"${TAG}\",
            \"name\": \"${RELEASE_TITLE}\",
            \"body\": \"${RELEASE_NOTES}\",
            \"draft\": false,
            \"prerelease\": false
        }" 2>/dev/null)

    RELEASE_ID=$(echo "$RESPONSE" | grep '"id"' | head -1 | grep -oE '[0-9]+')

    if [[ -z "$RELEASE_ID" ]]; then
        echo "ERROR: Failed to create release. Response:"
        echo "$RESPONSE"
        exit 1
    fi
    echo "Release created (id=${RELEASE_ID})"
fi

# Upload assets
upload_asset() {
    local filepath="$1"
    local filename; filename=$(basename "$filepath")
    echo ""
    echo "Uploading ${filename}..."

    # List existing assets on this release
    local assets_json
    assets_json=$(curl -s \
        -H "Authorization: token $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets")

    # Delete existing asset with the same name if it exists
    local existing_id
    existing_id=$(echo "$assets_json" \
        | grep -B2 "\"name\": \"${filename}\"" \
        | grep '"id":' | grep -oE '[0-9]+' | head -1)

    if [[ -n "$existing_id" ]]; then
        echo "  Removing existing asset (id=${existing_id})..."
        local del_http
        del_http=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: token $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -X DELETE \
            "https://api.github.com/repos/${REPO}/releases/assets/${existing_id}")
        echo "  Delete response: HTTP $del_http"
    fi

    echo "  Sending to GitHub upload API..."
    local upload_response http_code
    upload_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        -H "Authorization: token $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/octet-stream" \
        -X POST \
        "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=${filename}" \
        --data-binary "@${filepath}")

    http_code=$(echo "$upload_response" | grep "HTTP_CODE:" | grep -oE '[0-9]+')
    upload_response=$(echo "$upload_response" | grep -v "HTTP_CODE:")

    echo "  HTTP status: $http_code"

    local url
    url=$(echo "$upload_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('browser_download_url',''))" 2>/dev/null)
    if [[ -z "$url" ]]; then
        # fallback: grep for the specific field
        url=$(echo "$upload_response" | grep -o '"browser_download_url":"[^"]*"' | cut -d'"' -f4)
    fi
    if [[ -n "$url" ]]; then
        echo "  Uploaded: $url"
    else
        echo "  ERROR: Upload failed. Full response:"
        echo "$upload_response"
        exit 1
    fi
}

upload_asset "$OUTPUT"
upload_asset "$SCRIPT_DIR/alpha-wrapper-V${VERSION}.sha256"

echo ""
echo "================================================"
echo " Done!"
echo "================================================"
echo ""
echo "HiveOS Flight Sheet — Installation URL:"
echo "  https://github.com/${REPO}/releases/download/${TAG}/alpha-wrapper-V${VERSION}.tar.gz"
echo ""

# ---- Clean HiveOS cached installation so it re-downloads on next start ------
echo "Cleaning HiveOS cached installation..."
HIVE_MINER_DIR="/hive/miners/custom/alpha-wrapper"
HIVE_DOWNLOAD="/hive/miners/custom/downloads/alpha-wrapper-V${VERSION}.tar.gz"

if [[ -d "$HIVE_MINER_DIR" ]]; then
    rm -rf "$HIVE_MINER_DIR"
    echo "  Removed: $HIVE_MINER_DIR"
else
    echo "  Not found (skip): $HIVE_MINER_DIR"
fi

if [[ -f "$HIVE_DOWNLOAD" ]]; then
    rm -f "$HIVE_DOWNLOAD"
    echo "  Removed: $HIVE_DOWNLOAD"
else
    echo "  Not found (skip): $HIVE_DOWNLOAD"
fi

echo ""
echo "HiveOS will re-download and reinstall the wrapper on next miner start."
echo ""
