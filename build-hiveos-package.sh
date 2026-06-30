#!/usr/bin/env bash
#
# build-hiveos-package.sh
#
# Run this on Linux (Ubuntu / HiveOS rig) to produce the HiveOS-installable
# tarball with correct Unix permissions and LF line endings.
#
# Binaries and outputs are stored per-version in builds/{VERSION}/ so you
# can maintain multiple versions side by side without re-downloading.
#
# Usage:
#   bash build-hiveos-package.sh              # builds with default version (1.8.3)
#   bash build-hiveos-package.sh 1.8.5        # builds with specified version (auto-detect URL)
#   bash build-hiveos-package.sh 1.8.5 https://pearl.alphapool.tech/downloads/alpha-miner-1.8.5
#                                             # builds with explicit binary URL
#
# After build, you choose:
#   [L] Deploy locally to /hive/miners/custom/alpha-wrapper (test on this rig)
#   [G] Upload to GitHub release (publish for all rigs)
#   [B] Both
#   [N] Neither (just build)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER_DIR="$SCRIPT_DIR/alpha-wrapper"
VERSION="${1:-1.8.3}"
BINARY_URL="${2:-}"

# ---- Version-specific build directory ----------------------------------------
BUILD_DIR="$SCRIPT_DIR/builds/$VERSION"
mkdir -p "$BUILD_DIR"
BINARY_DEST="$BUILD_DIR/alpha"
OUTPUT="$BUILD_DIR/alpha-wrapper-V${VERSION}.tar.gz"

# If no explicit URL, try sources in order
if [[ -z "$BINARY_URL" ]]; then
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
echo " Build   : $BUILD_DIR"
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
    read -rp "Delete and re-download? [y/N]: " REDOWNLOAD
    if [[ "${REDOWNLOAD,,}" == "y" ]]; then
        rm -f "$BINARY_DEST"
    else
        echo "Keeping existing binary."
    fi
fi

if [[ ! -f "$BINARY_DEST" ]]; then
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

# ---- Inject version into h-manifest.conf ------------------------------------
echo ""
echo "Injecting version $VERSION into h-manifest.conf..."
sed -i "s/^CUSTOM_VERSION=.*/CUSTOM_VERSION=${VERSION}/" "$STAGE_DIR/alpha-wrapper/h-manifest.conf"
echo "  CUSTOM_VERSION=${VERSION}"

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
echo "$PACKAGE_SHA  alpha-wrapper-V${VERSION}.tar.gz" > "$BUILD_DIR/alpha-wrapper-V${VERSION}.sha256"
echo "Checksum saved to: builds/${VERSION}/alpha-wrapper-V${VERSION}.sha256"

# ==============================================================================
# ---- Deploy menu -------------------------------------------------------------
# ==============================================================================
echo ""
echo "================================================"
echo " Deploy"
echo "================================================"
echo ""
echo "  [L] Deploy locally — copy to /hive/miners/custom/alpha-wrapper (test on this rig)"
echo "  [G] Upload to GitHub release (publish for all rigs)"
echo "  [B] Both"
echo "  [N] Neither (just build, done)"
echo ""
read -rp "Choose [L/G/B/N]: " DEPLOY_CHOICE
DEPLOY_CHOICE="${DEPLOY_CHOICE,,}"  # lowercase

# ---- Local deploy ------------------------------------------------------------
deploy_local() {
    local HIVE_MINER_DIR="/hive/miners/custom/alpha-wrapper"
    echo ""
    echo "Deploying locally to $HIVE_MINER_DIR ..."

    # Copy files directly from staging dir (already has correct permissions + LF)
    # Don't touch /hive/miners/custom/downloads/ — if HiveOS doesn't find the
    # tar there it will force a re-download from GitHub on next restart.
    mkdir -p "$HIVE_MINER_DIR"

    # Copy each wrapper file individually (preserves permissions from staging)
    cp -f "$STAGE_DIR/alpha-wrapper/alpha"              "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/h-manifest.conf"    "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/h-config.sh"        "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/h-run.sh"           "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/h-stats.sh"         "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/alpha-supervise.sh" "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/alpha-stats.sh"     "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/alpha-events.sh"    "$HIVE_MINER_DIR/"
    cp -f "$STAGE_DIR/alpha-wrapper/miner.conf"         "$HIVE_MINER_DIR/"

    echo "  Copied all files to: $HIVE_MINER_DIR"
    echo ""
    echo "  Local deploy complete. Restart miner to use the new version:"
    echo "    miner restart"
    echo ""
}

# ---- GitHub upload -----------------------------------------------------------
deploy_github() {
    echo ""
    echo "Uploading to GitHub release..."

    # Try to load saved token
    local TOKEN_FILE="$HOME/.alpha-wrapper-gh-token"
    local GH_TOKEN=""
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
        return
    fi

    local REPO="nostalgia-mining/alpha-miner"
    local TAG="v${VERSION}-hiveos"
    local RELEASE_TITLE="HiveOS wrapper v${VERSION}"
    local RELEASE_NOTES="HiveOS wrapper v${VERSION} — see README for flight sheet setup."

    echo ""
    echo "Creating/updating GitHub Release ${TAG}..."

    # Check if release already exists
    local EXISTING
    EXISTING=$(curl -s \
        -H "Authorization: token $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" 2>/dev/null \
        | grep '"id"' | head -1 | grep -oE '[0-9]+' || true)

    local RELEASE_ID
    if [[ -n "$EXISTING" ]]; then
        echo "Release ${TAG} already exists (id=${EXISTING}) — will upload assets to it."
        RELEASE_ID="$EXISTING"
    else
        local RESPONSE
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
            return
        fi
        echo "Release created (id=${RELEASE_ID})"
    fi

    # Upload asset helper
    upload_asset() {
        local filepath="$1"
        local filename; filename=$(basename "$filepath")
        echo ""
        echo "Uploading ${filename}..."

        # Delete existing asset with same name
        local assets_json
        assets_json=$(curl -s \
            -H "Authorization: token $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets")

        local existing_id
        existing_id=$(echo "$assets_json" \
            | grep -B2 "\"name\": \"${filename}\"" \
            | grep '"id":' | grep -oE '[0-9]+' | head -1 || true)

        if [[ -n "$existing_id" ]]; then
            echo "  Removing existing asset (id=${existing_id})..."
            curl -s -o /dev/null \
                -H "Authorization: token $GH_TOKEN" \
                -H "Accept: application/vnd.github+json" \
                -X DELETE \
                "https://api.github.com/repos/${REPO}/releases/assets/${existing_id}"
        fi

        echo "  Uploading to GitHub..."
        local upload_response url
        upload_response=$(curl -s \
            -H "Authorization: token $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/octet-stream" \
            -X POST \
            "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=${filename}" \
            --data-binary "@${filepath}")

        url=$(echo "$upload_response" | grep -o '"browser_download_url":"[^"]*"' | cut -d'"' -f4)
        if [[ -n "$url" ]]; then
            echo "  Uploaded: $url"
        else
            echo "  ERROR: Upload may have failed. Response:"
            echo "$upload_response" | head -5
        fi
    }

    upload_asset "$OUTPUT"
    upload_asset "$BUILD_DIR/alpha-wrapper-V${VERSION}.sha256"

    echo ""
    echo "GitHub upload complete."
    echo ""
    echo "HiveOS Flight Sheet — Installation URL:"
    echo "  https://github.com/${REPO}/releases/download/${TAG}/alpha-wrapper-V${VERSION}.tar.gz"
    echo ""
}

# ---- Execute chosen deploy action --------------------------------------------
case "$DEPLOY_CHOICE" in
    l) deploy_local ;;
    g) deploy_github ;;
    b) deploy_local; deploy_github ;;
    n|"") echo ""; echo "Build only — done." ;;
    *) echo "Unknown choice '$DEPLOY_CHOICE' — skipping deploy." ;;
esac

echo ""
echo "================================================"
echo " Done! Build stored in: builds/${VERSION}/"
echo "================================================"
