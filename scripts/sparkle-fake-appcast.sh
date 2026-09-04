#!/usr/bin/env bash
#
# sparkle-fake-appcast.sh — Local smoke-test helper for Sparkle update flow.
#
# Purpose: validate that an installed Whytap-Beta.app build can detect,
# verify, and apply an EdDSA-signed update — without publishing a GitHub Release. Build
# a DMG with a higher CFBundleVersion than the installed app, point the
# installed app at http://localhost:8000/appcast.xml, run this script, and
# then click "Check for Updates…" in Whytap's menu bar.
#
# What it does:
#   1. Validates that an EdDSA-signed DMG exists in build/.
#   2. Asks Sparkle's `generate_appcast` to write appcast.xml with EdDSA
#      signatures, sourced from the keypair stored in your macOS Keychain.
#   3. Serves the staging directory over http://localhost:8000/ via Python.
#
# Usage:
#   FLAVOR=beta SHORT_VERSION=99.0.0 BUILD_VERSION=99999 \
#     ./scripts/build-dmg.sh   # with TEAM_ID / ASC_* exported (or via doppler run)
#   ./scripts/sparkle-fake-appcast.sh    # serves on :8000 until Ctrl-C
#
# Hint:
#   - Patch the installed Whytap-Beta.app to point its SUFeedURL at
#     http://localhost:8000/appcast.xml so Sparkle picks up this fake feed:
#       /usr/libexec/PlistBuddy -c "Set :SUFeedURL http://localhost:8000/appcast.xml" \
#         "/Applications/Whytap-Beta.app/Contents/Info.plist"
#     (Re-sign the app afterwards or expect Gatekeeper warnings.)
#   - Use a SHORT_VERSION higher than the installed app's CFBundleShortVersionString
#     and a BUILD_VERSION higher than its CFBundleVersion for Sparkle to offer
#     the update.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOR="${FLAVOR:-beta}"
PORT="${PORT:-8000}"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-}"

if [ -z "${APP_BUNDLE_NAME}" ]; then
    case "${FLAVOR}" in
        beta) APP_BUNDLE_NAME="Whytap-Beta" ;;
        prod) APP_BUNDLE_NAME="Whytap" ;;
        *)
            echo "ERROR: invalid FLAVOR='${FLAVOR}' (expected beta|prod)" >&2
            exit 1
            ;;
    esac
fi

GENERATE_APPCAST_BIN="$(find "${PROJECT_DIR}/.build" -name 'generate_appcast' -type f -perm -u+x | head -1)"
if [ -z "${GENERATE_APPCAST_BIN}" ]; then
    echo "ERROR: generate_appcast not found in .build/." >&2
    echo "Run 'swift build' first to fetch the Sparkle artifact bundle." >&2
    exit 1
fi

STAGING_DIR="${PROJECT_DIR}/build/fake-appcast"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Pull every signed DMG that matches this flavor into the staging dir;
# generate_appcast picks them up by file extension.
shopt -s nullglob
matching_dmgs=("${PROJECT_DIR}"/build/${APP_BUNDLE_NAME}-*.dmg)
shopt -u nullglob

if [ ${#matching_dmgs[@]} -eq 0 ]; then
    echo "ERROR: no DMG matching ${APP_BUNDLE_NAME}-*.dmg in build/." >&2
    echo "Run scripts/build-dmg.sh first (with a high SHORT_VERSION/BUILD_VERSION)." >&2
    exit 1
fi

for dmg in "${matching_dmgs[@]}"; do
    cp "${dmg}" "${STAGING_DIR}/"
done

echo "▶ Generating appcast.xml with EdDSA signatures..."
echo "  download URL prefix: http://localhost:${PORT}/"
"${GENERATE_APPCAST_BIN}" \
    --download-url-prefix "http://localhost:${PORT}/" \
    "${STAGING_DIR}/"

echo ""
echo "✓ Appcast staged at ${STAGING_DIR}/appcast.xml"
echo ""
echo "Serving http://localhost:${PORT}/ — Ctrl-C to stop."
echo "Patch installed app's SUFeedURL to http://localhost:${PORT}/appcast.xml,"
echo "then click 'Check for Updates…' in the Whytap menu bar."
echo ""

cd "${STAGING_DIR}"
exec python3 -m http.server "${PORT}"
