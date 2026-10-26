#!/usr/bin/env bash
#
# upload-release.sh - publish a built DMG as a GitHub Release and refresh the
# Sparkle appcast with Ed25519-signed archives, shipped as a release asset.
# Community updates use Sparkle Ed25519 signatures independently of Apple signing.
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
#   EXODIA_NOTARIZE      1 (default with the committed team) requires an
#                        Apple-notarized, stapled archive; 0 explicitly
#                        publishes a team archive without notarization
#
# Channels:
#   prod  -> tag v${SHORT_VERSION}. Assets: one
#            ${APP_BUNDLE_NAME}-latest.dmg (stable download link) and
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
        FEED_TAG="$TAG"
        FEED_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
        ;;
    beta)
        TAG="beta-v${SHORT_VERSION}-b${BUILD_VERSION}"
        TITLE="Whytap Beta ${SHORT_VERSION} (build ${BUILD_VERSION})"
        FEED_TAG="beta"
        FEED_URL="${DOWNLOAD_BASE}/beta/appcast.xml"
        ;;
esac

DMG_MANIFEST="${DMG_LOCAL}.manifest.json"
case "${EXODIA_LEGACY_SIGNED_RELEASE:-0}" in
    0) DISTRIBUTION_MODE="community" ;;
    1) DISTRIBUTION_MODE="developer-id" ;;
    *) echo "ERROR: EXODIA_LEGACY_SIGNED_RELEASE must be 0 or 1" >&2; exit 1 ;;
esac
# A community archive must carry the identity committed with its source: the
# Developer ID team when present, then the community certificate, otherwise
# ad-hoc. Test certificate overrides and ad-hoc opt-outs therefore cannot be
# published.
# WHY: .project-docs/decisions/2026-10-21-developer-id-team-signing.md
COMMUNITY_SIGNING_CERTIFICATE="${PROJECT_DIR}/Resources/community-signing-certificate.pem"
DEVELOPER_ID_TEAM_FILE="${PROJECT_DIR}/Resources/developer-id-team.txt"
if [ "${DISTRIBUTION_MODE}" = "developer-id" ]; then
    EXPECTED_CODE_SIGNING="developer-id"
elif [ -f "${DEVELOPER_ID_TEAM_FILE}" ]; then
    EXPECTED_CODE_SIGNING="team:$(tr -d '\n\r ' < "${DEVELOPER_ID_TEAM_FILE}")"
elif [ -f "${COMMUNITY_SIGNING_CERTIFICATE}" ]; then
    EXPECTED_CODE_SIGNING="certificate:$(/usr/bin/openssl x509 -in "${COMMUNITY_SIGNING_CERTIFICATE}" \
        -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"
else
    EXPECTED_CODE_SIGNING="adhoc"
fi
# A team release is published notarized unless EXODIA_NOTARIZE=0 says otherwise.
# WHY: docs/decisions/2026-10-21-notarized-releases.md
case "${EXODIA_NOTARIZE:-}" in
    ""|0|1) ;;
    *) echo "ERROR: EXODIA_NOTARIZE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "${DISTRIBUTION_MODE}" = "developer-id" ]; then
    EXPECTED_NOTARIZATION="notarized"
elif [[ "${EXPECTED_CODE_SIGNING}" == team:* ]]; then
    if [ "${EXODIA_NOTARIZE:-1}" = "1" ]; then
        EXPECTED_NOTARIZATION="notarized"
    else
        EXPECTED_NOTARIZATION="none"
        echo "WARN: publishing without Apple notarization (EXODIA_NOTARIZE=0); first launches need Open Anyway." >&2
    fi
elif [ "${EXODIA_NOTARIZE:-0}" = "1" ]; then
    echo "ERROR: EXODIA_NOTARIZE=1 needs the Developer ID team in Resources/developer-id-team.txt." >&2
    exit 1
else
    EXPECTED_NOTARIZATION="none"
fi
verify_archive_provenance() {
    /usr/bin/python3 "${PROJECT_DIR}/scripts/release-provenance.py" verify \
        --project-root "${PROJECT_DIR}" --archive "$1" --manifest "${DMG_MANIFEST}" \
        --version "${SHORT_VERSION}" --build "${BUILD_VERSION}" \
        --flavor "${FLAVOR}" --distribution "${DISTRIBUTION_MODE}" \
        --code-signing "${EXPECTED_CODE_SIGNING}" --notarization "${EXPECTED_NOTARIZATION}"
}
# Validate before key access or any GitHub operation. Never infer provenance from a filename.
SOURCE_SHA="$(verify_archive_provenance "${DMG_LOCAL}")"

# The manifest records the build's claim; check the archive itself as well.
if [ "${EXPECTED_NOTARIZATION}" = "notarized" ]; then
    if ! xcrun stapler validate "${DMG_LOCAL}" >/dev/null 2>&1; then
        echo "ERROR: ${DMG_FILENAME} has no valid stapled notarization ticket; refusing publication." >&2
        exit 1
    fi
    assessment_status=0
    assessment="$(spctl --assess -vv --type open --context context:primary-signature "${DMG_LOCAL}" 2>&1)" \
        || assessment_status=$?
    if [ "${assessment_status}" -ne 0 ] || [[ "${assessment}" != *"source=Notarized Developer ID"* ]]; then
        echo "ERROR: Gatekeeper does not accept ${DMG_FILENAME} as notarized; refusing publication." >&2
        printf '%s\n' "${assessment}" >&2
        exit 1
    fi
    echo "Notarized archive: stapled ticket and Gatekeeper assessment verified"
fi

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh (GitHub CLI) is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated (run: gh auth login)" >&2; exit 1; }

# Versioned asset URLs are immutable. Never overwrite an existing release,
# including a draft from a failed attempt; inspect it explicitly before retrying.
if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
   || gh api "repos/${GITHUB_REPO}/git/ref/tags/${TAG}" --silent >/dev/null 2>&1; then
    echo "ERROR: version tag ${TAG} already exists; refusing to overwrite its assets." >&2
    echo "Inspect the existing release/tag manually, then use a new version for publication." >&2
    exit 1
fi

# --- Locate Sparkle's generate_appcast ------------------------------------

GENERATE_APPCAST_BIN="$(find "${PROJECT_DIR}/.build" -name 'generate_appcast' -type f -perm -u+x | head -1)"
if [ -z "$GENERATE_APPCAST_BIN" ]; then
    echo "ERROR: generate_appcast not found in .build/ (build-dmg.sh builds Sparkle artifacts)" >&2
    exit 1
fi

SIGN_UPDATE_BIN="${GENERATE_APPCAST_BIN%/*}/sign_update"
if [ ! -x "${SIGN_UPDATE_BIN}" ]; then
    echo "ERROR: Sparkle sign_update is required to verify the generated archive signature." >&2
    exit 1
fi

# --- Stage private key + cleanup trap -------------------------------------

umask 077
STAGING_DIR="$(mktemp -d -t exodia-appcast-staging)"
SPARKLE_PRIV_FILE="$(mktemp -t exodia-sparkle-priv)"
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

prepare_appcast() {
    local appcast_path="$1"

    /usr/bin/python3 - "$appcast_path" "$APPCAST_MINIMUM_SYSTEM_VERSION" \
        "$BUILD_VERSION" "${DOWNLOAD_BASE}/${TAG}/${LATEST_FILENAME}" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path = sys.argv[1]
minimum_system_version = sys.argv[2]
build, archive_url = sys.argv[3:]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"

ET.register_namespace("sparkle", sparkle_ns)
tree = ET.parse(appcast_path)
root = tree.getroot()
nodes = root.findall(f".//{{{sparkle_ns}}}minimumSystemVersion")
if not nodes:
    raise SystemExit("appcast.xml has no sparkle:minimumSystemVersion entries")

for node in nodes:
    node.text = minimum_system_version

# The public filename is always latest; the enclosing release tag pins its
# bytes. Never point a signed update at the mutable releases/latest URL.
for item in root.findall("./channel/item"):
    if (item.findtext(f"{{{sparkle_ns}}}version") or "").strip() == build:
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise SystemExit("update item has no archive enclosure")
        enclosure.set("url", archive_url)

tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
PY
}

validate_signed_appcast_item() {
    /usr/bin/python3 - "$1" "$2" "$3" "$4" <<'PYXML'
import base64
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

appcast, build, archive, expected_url = sys.argv[1:]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(appcast).getroot()
items = [item for item in root.findall("./channel/item")
         if (item.findtext(f"{{{sparkle_ns}}}version") or "").strip() == build]
if len(items) != 1:
    raise SystemExit("expected exactly one appcast item for the new build")
enclosure = items[0].find("enclosure")
if enclosure is None:
    raise SystemExit("update item has no archive enclosure")
try:
    signature = base64.b64decode(enclosure.get(f"{{{sparkle_ns}}}edSignature", ""), validate=True)
    length = int(enclosure.get("length", "0"))
except (ValueError, TypeError):
    raise SystemExit("update item has invalid Ed25519 signature metadata")
if len(signature) != 64 or length != Path(archive).stat().st_size:
    raise SystemExit("update archive requires an Ed25519 signature and matching length")
if enclosure.get("url") != expected_url:
    raise SystemExit("update archive URL does not match its immutable release asset")
print("Signed update enclosure and archive length validated")
PYXML
}

# --- 1. Stage the new DMG next to the previous appcast --------------------

cp "$DMG_LOCAL" "${STAGING_DIR}/${DMG_FILENAME}"
# Close the source/copy gap and recheck the exact staged archive before publishing.
STAGED_SOURCE_SHA="$(verify_archive_provenance "${STAGING_DIR}/${DMG_FILENAME}")"
if [ "${STAGED_SOURCE_SHA}" != "${SOURCE_SHA}" ]; then
    echo "ERROR: archive source revision changed during staging; refusing publication." >&2
    exit 1
fi

echo "Fetching the current ${FLAVOR} appcast from ${GITHUB_REPO} (if any)..."
if [ "$FLAVOR" = "prod" ]; then
    gh release download --repo "$GITHUB_REPO" --pattern appcast.xml --dir "$STAGING_DIR" 2>/dev/null \
        || echo "No previous prod release with an appcast; starting a fresh feed."
else
    gh release download "$FEED_TAG" --repo "$GITHUB_REPO" --pattern appcast.xml --dir "$STAGING_DIR" 2>/dev/null \
        || echo "No rolling beta release yet; starting a fresh feed."
fi

# --- 2. Generate the appcast with signed archives -------------------------

echo "Generating appcast.xml with Ed25519-signed archives..."
"$GENERATE_APPCAST_BIN" \
    --download-url-prefix "${DOWNLOAD_BASE}/${TAG}/" \
    --maximum-deltas 0 \
    --ed-key-file "$SPARKLE_PRIV_FILE" \
    "${STAGING_DIR}/"

if [ ! -f "${STAGING_DIR}/appcast.xml" ]; then
    echo "ERROR: generate_appcast did not emit appcast.xml in ${STAGING_DIR}." >&2
    exit 1
fi
prepare_appcast "${STAGING_DIR}/appcast.xml"
cp "${STAGING_DIR}/${DMG_FILENAME}" "${STAGING_DIR}/${LATEST_FILENAME}"
if ! validate_signed_appcast_item "${STAGING_DIR}/appcast.xml" "$BUILD_VERSION" \
        "${STAGING_DIR}/${LATEST_FILENAME}" "${DOWNLOAD_BASE}/${TAG}/${LATEST_FILENAME}"; then
    echo "ERROR: appcast.xml has no valid signed update for build ${BUILD_VERSION}; refusing publication." >&2
    exit 1
fi

archive_signature="$(/usr/bin/python3 - "${STAGING_DIR}/appcast.xml" "$BUILD_VERSION" <<'PYSIGNATURE'
import sys
import xml.etree.ElementTree as ET
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
for item in ET.parse(sys.argv[1]).getroot().findall("./channel/item"):
    if (item.findtext(f"{{{ns}}}version") or "").strip() == sys.argv[2]:
        print(item.find("enclosure").get(f"{{{ns}}}edSignature"))
        break
PYSIGNATURE
)"
"${SIGN_UPDATE_BIN}" --verify --ed-key-file "$SPARKLE_PRIV_FILE" \
    "${STAGING_DIR}/${LATEST_FILENAME}" "${archive_signature}"

# --- 3. Stage a new draft, verify uploaded bytes, then publish last ----------

# Recheck immediately before creating the tag; target the verified build-time commit.
if [ "$(verify_archive_provenance "${STAGING_DIR}/${DMG_FILENAME}")" != "${SOURCE_SHA}" ]; then
    echo "ERROR: source revision changed before publication." >&2
    exit 1
fi
notes_args=(--generate-notes)
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    notes_args=(--notes-file "$RELEASE_NOTES_FILE")
fi

# Keep arrays nonempty for the macOS Bash 3.2 + set -u contract.
create_args=(--draft --target "$SOURCE_SHA" --title "$TITLE" "${notes_args[@]}")
if [ "$FLAVOR" = "beta" ]; then
    create_args+=(--prerelease)
fi
echo "Creating draft ${TAG} from source ${SOURCE_SHA}..."
gh release create "$TAG" --repo "$GITHUB_REPO" "${create_args[@]}"
# No --clobber: even a concurrent publisher cannot replace versioned bytes.
gh release upload "$TAG" --repo "$GITHUB_REPO" \
    "${STAGING_DIR}/${LATEST_FILENAME}" \
    "${STAGING_DIR}/appcast.xml"

VERIFY_DIR="$(mktemp -d "${STAGING_DIR}/verify.XXXXXX")"
gh release download "$TAG" --repo "$GITHUB_REPO" --dir "$VERIFY_DIR" \
    --pattern "$LATEST_FILENAME" --pattern appcast.xml
/usr/bin/python3 - "$STAGING_DIR" "$VERIFY_DIR" "$LATEST_FILENAME" <<'PYVERIFY'
import hashlib
from pathlib import Path
import sys

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.digest()

staging, downloaded = map(Path, sys.argv[1:3])
for name in [sys.argv[3], "appcast.xml"]:
    expected, actual = staging / name, downloaded / name
    if not actual.is_file() or actual.stat().st_size != expected.stat().st_size or digest(actual) != digest(expected):
        raise SystemExit("uploaded release asset bytes do not match; leaving the release as a draft")
print("Uploaded latest archive and appcast SHA256/length verified")
PYVERIFY

if [ "$FLAVOR" = "prod" ]; then
    gh release edit "$TAG" --repo "$GITHUB_REPO" --draft=false --latest
else
    gh release edit "$TAG" --repo "$GITHUB_REPO" --draft=false --latest=false
fi

# --- 4. Beta: update the mutable alias first and the rolling feed LAST -------

if [ "$FLAVOR" = "beta" ]; then
    if ! gh release view "$FEED_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        gh release create "$FEED_TAG" --repo "$GITHUB_REPO" --prerelease \
            --target "$SOURCE_SHA" --title "Whytap Beta feed" \
            --notes "Rolling prerelease that carries the beta Sparkle feed. Install from the versioned beta releases."
    fi
    gh release upload "$FEED_TAG" --repo "$GITHUB_REPO" --clobber \
        "${STAGING_DIR}/${LATEST_FILENAME}"
    gh release upload "$FEED_TAG" --repo "$GITHUB_REPO" --clobber \
        "${STAGING_DIR}/appcast.xml"
fi

echo ""
echo "Released ${LATEST_FILENAME}: ${DOWNLOAD_BASE}/${TAG}/${LATEST_FILENAME}"
echo "Latest alias: ${DOWNLOAD_BASE}/${FEED_TAG}/${LATEST_FILENAME}"
echo "Sparkle feed: ${FEED_URL}"
