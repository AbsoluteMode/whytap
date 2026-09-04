#!/usr/bin/env bash
#
# user-release.sh - the Whytap release path.
#
# One command: build, sign and notarize the DMG on a Mac, then publish it as
# a GitHub Release together with the EdDSA-signed Sparkle appcast so that
# installed copies get the in-app update. No CI runners are involved.
#
# WHY: docs/decisions/2026-09-04-github-releases-as-update-feed.md
#
# Usage:
#   FLAVOR=prod ./scripts/user-release.sh
#   FLAVOR=beta ./scripts/user-release.sh
#   FLAVOR=prod ./scripts/user-release.sh --build-only
#   FLAVOR=prod ./scripts/user-release.sh --dry-run
#   FLAVOR=prod SHORT_VERSION=2.0.1 BUILD_VERSION=1450 \
#     ./scripts/user-release.sh --upload-only
#
# Credentials come from the environment. The official releases inject them
# with `doppler run --project sidekey --config dev -- ./scripts/user-release.sh`;
# a fork exports them directly:
#   TEAM_ID                      Apple Developer Team ID (Developer ID signing)
#   ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID, ASC_API_KEY_P8   notarization
#   SPARKLE_ED_PRIVATE_KEY       base64 Ed25519 seed (see sparkle-keys-bootstrap.sh)
#   GITHUB_REPO                  owner/name (default: AbsoluteMode/whytap)
#   plus an authenticated `gh` CLI.
#
# Optional:
#   SHORT_VERSION       default: max(VERSION, live appcast shortVersionString)
#   BUILD_VERSION       default: max(live appcast build, installed build) + 1
#   RELEASE_NOTES_FILE  markdown body for the GitHub Release

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<'EOF2'
user-release.sh - the Whytap release path (local build -> GitHub Releases -> Sparkle).

Usage:
  FLAVOR=prod ./scripts/user-release.sh
  FLAVOR=beta ./scripts/user-release.sh
  FLAVOR=prod ./scripts/user-release.sh --build-only
  FLAVOR=prod ./scripts/user-release.sh --dry-run
  FLAVOR=prod SHORT_VERSION=2.0.1 BUILD_VERSION=1450 \
    ./scripts/user-release.sh --upload-only

Required in the environment (or via `doppler run -- ...`):
  TEAM_ID, ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID, ASC_API_KEY_P8,
  SPARKLE_ED_PRIVATE_KEY, an authenticated gh CLI

Optional:
  GITHUB_REPO         default: AbsoluteMode/whytap
  SHORT_VERSION       default: max(VERSION, live appcast shortVersionString)
  BUILD_VERSION       default: max(live appcast build, installed build) + 1
  RELEASE_NOTES_FILE  markdown body for the GitHub Release
EOF2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

BUILD_STEP=1
UPLOAD_STEP=1
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-only)
            BUILD_STEP=1
            UPLOAD_STEP=0
            ;;
        --upload-only|--skip-build)
            BUILD_STEP=0
            UPLOAD_STEP=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

GITHUB_REPO="${GITHUB_REPO:-AbsoluteMode/whytap}"
FLAVOR="${FLAVOR:-prod}"
case "$FLAVOR" in
    prod)
        APP_BUNDLE_NAME="Whytap"
        APPCAST_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
        INSTALLED_APP="/Applications/Whytap.app"
        ;;
    beta)
        APP_BUNDLE_NAME="Whytap-Beta"
        APPCAST_URL="https://github.com/${GITHUB_REPO}/releases/download/beta/appcast.xml"
        INSTALLED_APP="/Applications/Whytap-Beta.app"
        ;;
    *)
        die "invalid FLAVOR='${FLAVOR}' (expected prod or beta)"
        ;;
esac

[ -x /usr/bin/python3 ] || die "missing /usr/bin/python3"
if [ "$DRY_RUN" -eq 0 ] && [ "$UPLOAD_STEP" -eq 1 ]; then
    need_cmd gh
fi

repo_short_version="$(tr -d '\n\r ' < "${PROJECT_DIR}/VERSION")"
if ! [[ "$repo_short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    die "invalid VERSION file content: '${repo_short_version}'"
fi

fetch_appcast_meta() {
    /usr/bin/python3 - "$APPCAST_URL" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET

url = sys.argv[1]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"

request = urllib.request.Request(
    url,
    headers={"User-Agent": "whytap-local-release/2.0"},
)
with urllib.request.urlopen(request, timeout=15) as response:
    root = ET.fromstring(response.read())

best = None
for item in root.findall("./channel/item"):
    build_node = item.find(f"{{{sparkle_ns}}}version")
    short_node = item.find(f"{{{sparkle_ns}}}shortVersionString")
    if build_node is None or short_node is None:
        continue
    try:
        build = int((build_node.text or "").strip())
    except ValueError:
        continue
    short = (short_node.text or "").strip()
    if not short:
        continue
    if best is None or build > best[1]:
        best = (short, build)

if best is None:
    raise SystemExit("no Sparkle items with build + short version")

print(f"{best[0]}\t{best[1]}")
PY
}

version_cmp() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import sys

def parse(version):
    main, sep, prerelease = version.partition("-")
    parts = main.split(".")
    if len(parts) != 3:
        raise ValueError(version)
    nums = tuple(int(part) for part in parts)
    return nums + ((1 if not sep else 0), prerelease)

a = parse(sys.argv[1])
b = parse(sys.argv[2])
print((a > b) - (a < b))
PY
}

remote_short_version=""
remote_build_version=""
if remote_meta="$(fetch_appcast_meta 2>&1)"; then
    IFS=$'\t' read -r remote_short_version remote_build_version <<< "$remote_meta"
else
    warn "could not read live appcast (${APPCAST_URL}): ${remote_meta}"
fi

if [ -n "${SHORT_VERSION:-}" ]; then
    if ! [[ "$SHORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        die "invalid SHORT_VERSION='${SHORT_VERSION}'"
    fi
else
    SHORT_VERSION="$repo_short_version"
    if [ -n "$remote_short_version" ]; then
        cmp="$(version_cmp "$remote_short_version" "$SHORT_VERSION")"
        if [ "$cmp" = "1" ]; then
            SHORT_VERSION="$remote_short_version"
        fi
    fi
fi

if [ -n "$remote_short_version" ]; then
    cmp="$(version_cmp "$SHORT_VERSION" "$remote_short_version")"
    if [ "$cmp" = "-1" ] && [ "${ALLOW_SHORT_VERSION_REGRESSION:-0}" != "1" ]; then
        die "SHORT_VERSION='${SHORT_VERSION}' is older than live ${FLAVOR} short version '${remote_short_version}'. Set SHORT_VERSION=${remote_short_version} or bump VERSION."
    fi
fi

installed_build_version=""
installed_plist="${INSTALLED_APP}/Contents/Info.plist"
if [ -f "$installed_plist" ]; then
    installed_build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_plist" 2>/dev/null || true)"
fi

max_seen_build=0
if [[ "$remote_build_version" =~ ^[0-9]+$ ]] && [ "$remote_build_version" -gt "$max_seen_build" ]; then
    max_seen_build="$remote_build_version"
fi
if [[ "$installed_build_version" =~ ^[0-9]+$ ]] && [ "$installed_build_version" -gt "$max_seen_build" ]; then
    max_seen_build="$installed_build_version"
fi

if [ -n "${BUILD_VERSION:-}" ]; then
    [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || die "BUILD_VERSION must be an integer (got '${BUILD_VERSION}')"
else
    [ "$max_seen_build" -gt 0 ] || die "could not infer BUILD_VERSION; set BUILD_VERSION manually"
    BUILD_VERSION=$(( max_seen_build + 1 ))
fi

if [ "$BUILD_VERSION" -le "$max_seen_build" ] && [ "${ALLOW_BUILD_VERSION_REUSE:-0}" != "1" ]; then
    die "BUILD_VERSION=${BUILD_VERSION} is not newer than live/installed max ${max_seen_build}"
fi

export FLAVOR
export SHORT_VERSION
export BUILD_VERSION
export APP_BUNDLE_NAME
export GITHUB_REPO

echo "User release (local build -> GitHub Releases -> Sparkle)"
echo "Repository: ${GITHUB_REPO}"
echo "Flavor: ${FLAVOR}"
echo "Short version: ${SHORT_VERSION}"
echo "Build version: ${BUILD_VERSION}"
if [ -n "$remote_build_version" ]; then
    echo "Live appcast build: ${remote_build_version} (${remote_short_version})"
fi
if [ -n "$installed_build_version" ]; then
    echo "Installed build: ${installed_build_version}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run: no build or upload."
    exit 0
fi

missing=()
if [ "$BUILD_STEP" -eq 1 ]; then
    for var in TEAM_ID ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8; do
        [ -n "${!var:-}" ] || missing+=("$var")
    done
fi
if [ "$UPLOAD_STEP" -eq 1 ]; then
    if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ] && [ -z "${SPARKLE_ED_PRIVATE_KEY_FILE:-}" ]; then
        missing+=("SPARKLE_ED_PRIVATE_KEY")
    fi
fi
if [ "${#missing[@]}" -gt 0 ]; then
    die "missing credentials in the environment: ${missing[*]} (wrap with 'doppler run -- ...' or export them; see docs/build-and-release.md)"
fi

cd "$PROJECT_DIR"

if [ "$BUILD_STEP" -eq 1 ]; then
    ./scripts/build-dmg.sh
fi

if [ "$UPLOAD_STEP" -eq 1 ]; then
    ./scripts/upload-release.sh
fi

echo ""
echo "Done: ${APP_BUNDLE_NAME}-${SHORT_VERSION}-build${BUILD_VERSION}"
