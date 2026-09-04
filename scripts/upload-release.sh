#!/usr/bin/env bash
#
# upload-release.sh - publish a built DMG as a GitHub Release and refresh the
# EdDSA-signed Sparkle appcast that ships as a release asset.
#
# Called by scripts/user-release.sh after build-dmg.sh produces:
#   build/${APP_BUNDLE_NAME}-${SHORT_VERSION}-build${BUILD_VERSION}.dmg
#
# Required env:
#   FLAVOR               "prod" | "beta"
#   APP_BUNDLE_NAME      "Whytap" | "Whytap-Beta"
#   SHORT_VERSION        SemVer (e.g. 2.0.0)
#   BUILD_VERSION        monotonic int (e.g. 1444); Sparkle compares this
#   SPARKLE_ED_PRIVATE_KEY        base64 Ed25519 seed (32 bytes decoded), OR
#   SPARKLE_ED_PRIVATE_KEY_FILE   path to a file holding the same value
#
# Optional env:
#   GITHUB_REPO          owner/name (default: AbsoluteMode/whytap)
#   RELEASE_NOTES_FILE   markdown file used as the release body
#                        (default: GitHub auto-generated notes)
#
# Channels:
#   prod  -> tag v${SHORT_VERSION}. Assets: the versioned DMG, a
#            ${APP_BUNDLE_NAME}-latest.dmg copy (stable download link) and
#            appcast.xml. The app's feed URL is
#            https://github.com/<repo>/releases/latest/download/appcast.xml,
#            so the newest non-prerelease release always carries the feed.
#   beta  -> tag beta-v${SHORT_VERSION}-b${BUILD_VERSION}, marked prerelease,
#            plus a rolling prerelease tagged "beta" whose appcast.xml and
#            latest alias are overwritten every time. Feed URL:
#            https://github.com/<repo>/releases/download/beta/appcast.xml
#
# The previous appcast.xml is downloaded first so generate_appcast keeps the
# older items (their enclosure URLs point at their own release tags). No
# delta updates: every item is a full DMG.

set -euo pipefail

required=(FLAVOR APP_BUNDLE_NAME SHORT_VERSION BUILD_VERSION)
missing=()
for var in "${required[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing+=("$var")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing required env vars: ${missing[*]}" >&2
    exit 1
fi

case "$FLAVOR" in
    beta|prod) ;;
    *)
        echo "ERROR: invalid FLAVOR='${FLAVOR}' (expected beta|prod)" >&2
        exit 1
        ;;
esac

if ! [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
    echo "ERROR: BUILD_VERSION must be an integer (got '${BUILD_VERSION}')" >&2
    exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh (GitHub CLI) is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated (run: gh auth login)" >&2; exit 1; }

GITHUB_REPO="${GITHUB_REPO:-AbsoluteMode/whytap}"
DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST_MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :LSMinimumSystemVersion' \
    "${PROJECT_DIR}/Resources/Info.plist.template")"

DMG_FILENAME="${APP_BUNDLE_NAME}-${SHORT_VERSION}-build${BUILD_VERSION}.dmg"
DMG_LOCAL="${PROJECT_DIR}/build/${DMG_FILENAME}"
LATEST_FILENAME="${APP_BUNDLE_NAME}-latest.dmg"

if [ ! -f "$DMG_LOCAL" ]; then
    echo "ERROR: expected DMG not found at $DMG_LOCAL (did build-dmg.sh succeed?)" >&2
    exit 1
fi

case "$FLAVOR" in
    prod)
        TAG="v${SHORT_VERSION}"
        TITLE="Whytap ${SHORT_VERSION}"
        PRERELEASE_FLAG=()
        FEED_TAG="$TAG"
        FEED_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
        ;;
    beta)
        TAG="beta-v${SHORT_VERSION}-b${BUILD_VERSION}"
        TITLE="Whytap Beta ${SHORT_VERSION} (build ${BUILD_VERSION})"
        PRERELEASE_FLAG=(--prerelease)
        FEED_TAG="beta"
        FEED_URL="${DOWNLOAD_BASE}/beta/appcast.xml"
        ;;
esac

# --- Locate Sparkle's generate_appcast ------------------------------------

GENERATE_APPCAST_BIN="$(find "${PROJECT_DIR}/.build" -name 'generate_appcast' -type f -perm -u+x | head -1)"
if [ -z "$GENERATE_APPCAST_BIN" ]; then
    echo "ERROR: generate_appcast not found in .build/ (build-dmg.sh builds Sparkle artifacts)" >&2
    exit 1
fi

# --- Stage private key + cleanup trap -------------------------------------

umask 077
STAGING_DIR="$(mktemp -d -t whytap-appcast-staging)"
SPARKLE_PRIV_FILE="$(mktemp -t whytap-sparkle-priv)"
chmod 600 "$SPARKLE_PRIV_FILE"

cleanup() {
    if [ -f "${SPARKLE_PRIV_FILE:-}" ]; then
        if command -v dd >/dev/null 2>&1; then
            local size
            size="$(wc -c < "$SPARKLE_PRIV_FILE" 2>/dev/null || echo 0)"
            if [ "${size:-0}" -gt 0 ]; then
                dd if=/dev/zero of="$SPARKLE_PRIV_FILE" bs=1 count="$size" \
                    conv=notrunc >/dev/null 2>&1 || true
            fi
        fi
        rm -f "$SPARKLE_PRIV_FILE"
    fi
    if [ -d "${STAGING_DIR:-}" ]; then
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

if [ -n "${SPARKLE_ED_PRIVATE_KEY_FILE:-}" ]; then
    tr -d '\n\r ' < "$SPARKLE_ED_PRIVATE_KEY_FILE" > "$SPARKLE_PRIV_FILE"
elif [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | tr -d '\n\r ' > "$SPARKLE_PRIV_FILE"
else
    echo "ERROR: set SPARKLE_ED_PRIVATE_KEY or SPARKLE_ED_PRIVATE_KEY_FILE" >&2
    echo "       (scripts/sparkle-keys-bootstrap.sh creates a key pair for a fork)" >&2
    exit 1
fi

priv_len="$(base64 -d < "$SPARKLE_PRIV_FILE" 2>/dev/null | wc -c | tr -d ' ')"
if [ "$priv_len" != "32" ]; then
    echo "ERROR: the Sparkle private key does not decode to 32 bytes (got ${priv_len})." >&2
    exit 1
fi

normalize_appcast_minimum_system_version() {
    local appcast_path="$1"

    /usr/bin/python3 - "$appcast_path" "$APPCAST_MINIMUM_SYSTEM_VERSION" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path = sys.argv[1]
minimum_system_version = sys.argv[2]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"

ET.register_namespace("sparkle", sparkle_ns)
tree = ET.parse(appcast_path)
root = tree.getroot()
nodes = root.findall(f".//{{{sparkle_ns}}}minimumSystemVersion")
if not nodes:
    raise SystemExit("appcast.xml has no sparkle:minimumSystemVersion entries")

for node in nodes:
    node.text = minimum_system_version

tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
PY
}

appcast_has_build() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(sys.argv[1]).getroot()
builds = [
    (node.text or "").strip()
    for node in root.findall(f"./channel/item/{{{sparkle_ns}}}version")
]
print(f"items: {len(builds)}")
raise SystemExit(0 if sys.argv[2] in builds else 1)
PY
}

# --- 1. Stage the new DMG next to the previous appcast --------------------

cp "$DMG_LOCAL" "${STAGING_DIR}/${DMG_FILENAME}"

echo "Fetching the current ${FLAVOR} appcast from ${GITHUB_REPO} (if any)..."
if [ "$FLAVOR" = "prod" ]; then
    gh release download --repo "$GITHUB_REPO" --pattern appcast.xml --dir "$STAGING_DIR" 2>/dev/null \
        || echo "No previous prod release with an appcast; starting a fresh feed."
else
    gh release download "$FEED_TAG" --repo "$GITHUB_REPO" --pattern appcast.xml --dir "$STAGING_DIR" 2>/dev/null \
        || echo "No rolling beta release yet; starting a fresh feed."
fi

# --- 2. Generate the signed appcast ---------------------------------------

echo "Generating EdDSA-signed appcast.xml..."
"$GENERATE_APPCAST_BIN" \
    --download-url-prefix "${DOWNLOAD_BASE}/${TAG}/" \
    --maximum-deltas 0 \
    --ed-key-file "$SPARKLE_PRIV_FILE" \
    "${STAGING_DIR}/"

if [ ! -f "${STAGING_DIR}/appcast.xml" ]; then
    echo "ERROR: generate_appcast did not emit appcast.xml in ${STAGING_DIR}." >&2
    exit 1
fi
normalize_appcast_minimum_system_version "${STAGING_DIR}/appcast.xml"
if ! appcast_has_build "${STAGING_DIR}/appcast.xml" "$BUILD_VERSION"; then
    echo "ERROR: appcast.xml does not contain build ${BUILD_VERSION}." >&2
    exit 1
fi

cp "${STAGING_DIR}/${DMG_FILENAME}" "${STAGING_DIR}/${LATEST_FILENAME}"

# --- 3. Create (or refresh) the GitHub Release ----------------------------

notes_args=(--generate-notes)
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    notes_args=(--notes-file "$RELEASE_NOTES_FILE")
fi

if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "Release ${TAG} exists; replacing its assets..."
    gh release upload "$TAG" --repo "$GITHUB_REPO" --clobber \
        "${STAGING_DIR}/${DMG_FILENAME}" \
        "${STAGING_DIR}/${LATEST_FILENAME}" \
        "${STAGING_DIR}/appcast.xml"
else
    echo "Creating release ${TAG}..."
    gh release create "$TAG" --repo "$GITHUB_REPO" \
        --title "$TITLE" "${notes_args[@]}" "${PRERELEASE_FLAG[@]}" \
        "${STAGING_DIR}/${DMG_FILENAME}" \
        "${STAGING_DIR}/${LATEST_FILENAME}" \
        "${STAGING_DIR}/appcast.xml"
fi

# --- 4. Beta: refresh the rolling feed release -----------------------------

if [ "$FLAVOR" = "beta" ]; then
    if ! gh release view "$FEED_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        gh release create "$FEED_TAG" --repo "$GITHUB_REPO" --prerelease \
            --title "Whytap Beta feed" \
            --notes "Rolling prerelease that carries the beta Sparkle feed. Install from the versioned beta releases."
    fi
    gh release upload "$FEED_TAG" --repo "$GITHUB_REPO" --clobber \
        "${STAGING_DIR}/appcast.xml" \
        "${STAGING_DIR}/${LATEST_FILENAME}"
fi

echo ""
echo "Released ${DMG_FILENAME}: ${DOWNLOAD_BASE}/${TAG}/${DMG_FILENAME}"
echo "Latest alias: ${DOWNLOAD_BASE}/${FEED_TAG}/${LATEST_FILENAME}"
echo "Sparkle feed: ${FEED_URL}"
