#!/bin/bash
#
# build-dmg.sh — Build a universal community Whytap DMG.
# Default: the Developer ID certificate of the Apple team committed in
# Resources/developer-id-team.txt, from the login keychain, without
# notarization. EXODIA_NOTARIZE=1 also notarizes and staples the app and the
# DMG with the team's App Store Connect API key from Whytap Case.
# Without that file: Whytap's self-signed community certificate
# when Resources/community-signing-certificate.pem is committed, otherwise
# ad-hoc; neither needs an Apple Developer account nor can be notarized.
# The older Developer-ID/notarization path stays behind EXODIA_LEGACY_SIGNED_RELEASE=1.
#
# Usage:
#   FLAVOR=beta|prod \
#   SHORT_VERSION=2.1.0 \
#   BUILD_VERSION=42 \
#     ./scripts/build-dmg.sh
#
# Env (all optional with defaults):
#   FLAVOR         beta|prod   (default: prod)
#   SHORT_VERSION  SemVer       (default: VERSION file)
#   BUILD_VERSION  monotonic    (default: 1; user-release picks next live build)
#                  integer
#   EXODIA_DMG_HEADLESS  0|1 compatibility flag; layout is always written offline
#   EXODIA_COMMUNITY_SIGNING  auto|adhoc (default: auto = committed identity)
#   EXODIA_DEVELOPER_ID_IDENTITY  SHA-1 of the team's Developer ID Application
#                  identity; needed only when the keychain holds several
#   EXODIA_COMMUNITY_SIGNING_KEY or EXODIA_COMMUNITY_SIGNING_KEY_FILE
#                  PEM private key of the community certificate (Doppler, never printed)
#   EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE  test-only certificate override;
#                  its archives cannot be published
#   EXODIA_NOTARIZE  0|1 (default: 0) notarize a team-signed build; needs
#                  ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID and ASC_API_KEY_P8 in
#                  Whytap Case project whytap (never in the environment)
#   EXODIA_CASE_HELPER  Case command (default: the installed Whytap's
#                  Contents/Helpers/whytap)
#
# Community requirements: local Swift/Xcode macOS 26 SDK and build resources;
# team signing also needs the Developer ID certificate and network access for
# Apple's signing timestamp; notarization also needs Apple's notary service.
# Optional legacy mode additionally needs TEAM_ID and ASC_API_KEY_* credentials.
# --preflight-only validates the selected build path without building or publishing.
#
# Outputs:
#   - build/${APP_BUNDLE_NAME}-${SHORT_VERSION}-build${BUILD_VERSION}.dmg
#     where APP_BUNDLE_NAME = Whytap (prod) or Whytap-Beta (beta).

set -euo pipefail

LEGACY_SIGNED_RELEASE="${EXODIA_LEGACY_SIGNED_RELEASE:-0}"
case "${LEGACY_SIGNED_RELEASE}" in
    0) DISTRIBUTION_MODE="community"; SIGNING_IDENTITY="-"; SIGNING_TIMESTAMP_ARGS=(--timestamp=none) ;;
    1) DISTRIBUTION_MODE="developer-id"; SIGNING_TIMESTAMP_ARGS=(--timestamp) ;;
    *) echo "ERROR: EXODIA_LEGACY_SIGNED_RELEASE must be 0 or 1" >&2; exit 2 ;;
esac
# WHY: docs/decisions/2026-10-21-notarized-releases.md
NOTARIZE="${EXODIA_NOTARIZE:-0}"
case "${NOTARIZE}" in
    0|1) ;;
    *) echo "ERROR: EXODIA_NOTARIZE must be 0 or 1" >&2; exit 2 ;;
esac
# The legacy mode always notarized, with its key in the environment.
NOTARY_CREDENTIALS="case"
if [ "${LEGACY_SIGNED_RELEASE}" = "1" ]; then
    NOTARIZE=1
    NOTARY_CREDENTIALS="environment"
fi
NOTARY_CASE_PROJECT="whytap"
NOTARY_KEYS="ASC_API_KEY_ID,ASC_API_KEY_ISSUER_ID,ASC_API_KEY_P8"
CASE_HELPER="${EXODIA_CASE_HELPER:-/Applications/Whytap.app/Contents/Helpers/whytap}"
DMG_HEADLESS="${EXODIA_DMG_HEADLESS:-0}"
case "${DMG_HEADLESS}" in
    0|1) ;;
    *) echo "ERROR: EXODIA_DMG_HEADLESS must be 0 or 1" >&2; exit 2 ;;
esac
PREFLIGHT_ONLY=0
for argument in "$@"; do
    case "${argument}" in
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        *) echo "ERROR: unknown argument: ${argument}" >&2; exit 2 ;;
    esac
done
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Flavor parameterisation ---------------------------------------------

FLAVOR="${FLAVOR:-prod}"
SHORT_VERSION="${SHORT_VERSION:-$(tr -d '\n\r ' < "${PROJECT_DIR}/VERSION")}"
BUILD_VERSION="${BUILD_VERSION:-1}"

if ! [[ "$SHORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo "ERROR: SHORT_VERSION must be a semantic version" >&2
    exit 1
fi

if ! [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || [ "$BUILD_VERSION" -le 0 ]; then
    echo "ERROR: BUILD_VERSION must be a positive integer (got: '${BUILD_VERSION}')" >&2
    exit 1
fi

# SwiftPM (native build backend) names the built binary after the PRODUCT:
# the consumer line is product "Sidekey" (thin executable target SidekeyApp
# wrapping the shared "Sidekey" library — see Package.swift), so the
# artifact stays .build/release/Sidekey and CFBundleExecutable is stable
# across the product-line split. The .app bundle wrapping it can be named
# differently per flavor (Whytap.app vs Whytap-Beta.app) so both flavors
# can sit side-by-side in /Applications without colliding.
EXECUTABLE_NAME="Sidekey"
BUNDLE_ICON_FILE="AppIcon"

case "$FLAVOR" in
    beta)
        APP_BUNDLE_NAME="Whytap-Beta"
        BUNDLE_ID="com.rootwise.sidekey.beta"
        BUNDLE_DISPLAY_NAME="Whytap Beta"
        SWIFT_FLAGS="-Xswiftc -DBETA"
        APPCAST_URL="${APPCAST_URL:-https://github.com/${GITHUB_REPO:-AbsoluteMode/whytap}/releases/download/beta/appcast.xml}"
        ;;
    prod)
        APP_BUNDLE_NAME="Whytap"
        BUNDLE_ID="com.rootwise.sidekey"
        BUNDLE_DISPLAY_NAME="Whytap"
        SWIFT_FLAGS=""
        APPCAST_URL="${APPCAST_URL:-https://github.com/${GITHUB_REPO:-AbsoluteMode/whytap}/releases/latest/download/appcast.xml}"
        ;;
    *)
        echo "ERROR: invalid FLAVOR='${FLAVOR}' (expected beta|prod)" >&2
        exit 1
        ;;
esac

if [ "${LEGACY_SIGNED_RELEASE}" = "1" ]; then
    TEAM_ID="${TEAM_ID:?set TEAM_ID for the explicitly selected Developer ID release}"
    SIGNING_IDENTITY="${TEAM_ID}"
fi
# BUILD_DIR points at the staged universal executable produced below by
# per-architecture native builds and lipo (see the Build section).
BUILD_DIR=""
APP_BUNDLE="${PROJECT_DIR}/build/${APP_BUNDLE_NAME}.app"
APP_ZIP="${PROJECT_DIR}/build/${APP_BUNDLE_NAME}.zip"
DMG_PATH="${PROJECT_DIR}/build/${APP_BUNDLE_NAME}-${SHORT_VERSION}-build${BUILD_VERSION}.dmg"
DMG_ROOT=""
DMG_RW_PATH=""
DMG_MOUNT_POINT=""
ENTITLEMENTS="${PROJECT_DIR}/Resources/Sidekey.entitlements"
INFO_PLIST_TEMPLATE="${PROJECT_DIR}/Resources/Info.plist.template"
SPARKLE_PUBKEY_FILE="${PROJECT_DIR}/Resources/sparkle-public-ed-key.txt"
DMG_BACKGROUND_SRC="${PROJECT_DIR}/Resources/dmg-background.png"
DMG_LAYOUT="${PROJECT_DIR}/scripts/dmg-layout.py"
MENU_BAR_ICON="${PROJECT_DIR}/Resources/MenuBarIconTemplate.pdf"

# --- Community code-signing identity -------------------------------------
# WHY: .project-docs/decisions/2026-10-19-community-signing-identity.md
# An ad-hoc designated requirement is the cdhash, so TCC treats every update
# as a new app and Microphone/System Audio must be granted again. A committed
# self-signed certificate keeps it at identifier + certificate leaf hash
# across builds; its private key lives in Doppler like the Sparkle key.
# WHY: .project-docs/decisions/2026-10-21-developer-id-team-signing.md
# Without an Apple team ID the keychain still partitions every item by the
# build's cdhash, so each update asked for every stored key again. The team
# committed in Resources/developer-id-team.txt takes precedence: its Developer
# ID certificate gives every build the team's requirement and keychain partition.
COMMUNITY_SIGNING="${EXODIA_COMMUNITY_SIGNING:-auto}"
case "${COMMUNITY_SIGNING}" in
    auto|adhoc) ;;
    *) echo "ERROR: EXODIA_COMMUNITY_SIGNING must be auto or adhoc" >&2; exit 2 ;;
esac
CODE_SIGNING="adhoc"
SIGNING_TEAM_ID=""
SIGNING_CERTIFICATE_FILE=""
SIGNING_CERTIFICATE_SHA1=""
EXPECTED_DESIGNATED_REQUIREMENT=""
# Requirement for the nested code and the DMG; empty when signing ad hoc.
SIGNER_REQUIREMENT=""
if [ "${LEGACY_SIGNED_RELEASE}" = "1" ]; then
    CODE_SIGNING="developer-id"
elif [ "${COMMUNITY_SIGNING}" = "auto" ]; then
    if [ -n "${EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE:-}" ]; then
        SIGNING_CERTIFICATE_FILE="${EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE}"
        if [ ! -f "${SIGNING_CERTIFICATE_FILE}" ]; then
            echo "ERROR: EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE is not a file: ${SIGNING_CERTIFICATE_FILE}" >&2
            exit 1
        fi
    elif [ -f "${PROJECT_DIR}/Resources/developer-id-team.txt" ]; then
        SIGNING_TEAM_ID="$(tr -d '\n\r ' < "${PROJECT_DIR}/Resources/developer-id-team.txt")"
        if ! [[ "${SIGNING_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
            echo "ERROR: Resources/developer-id-team.txt must hold a 10-character Apple team ID." >&2
            exit 1
        fi
    elif [ -f "${PROJECT_DIR}/Resources/community-signing-certificate.pem" ]; then
        SIGNING_CERTIFICATE_FILE="${PROJECT_DIR}/Resources/community-signing-certificate.pem"
    fi
fi

# Prints the community signing key; callers only pipe it into openssl.
community_signing_key() {
    if [ -n "${EXODIA_COMMUNITY_SIGNING_KEY_FILE:-}" ]; then
        cat "${EXODIA_COMMUNITY_SIGNING_KEY_FILE}"
    else
        printf '%s\n' "${EXODIA_COMMUNITY_SIGNING_KEY:-}"
    fi
}

wipe_file() {
    local size
    if [ -f "$1" ]; then
        size="$(wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "${size:-0}" -gt 0 ]; then
            dd if=/dev/zero of="$1" bs=1 count="${size}" conv=notrunc >/dev/null 2>&1 || true
        fi
        rm -f "$1"
    fi
}

# $1 = signed code, $2 = requirement it must satisfy.
require_signature() {
    if ! codesign --verify --strict --all-architectures -R "=$2" "$1" >/dev/null 2>&1; then
        echo "ERROR: ${1#"${PROJECT_DIR}"/} does not satisfy: $2" >&2
        exit 1
    fi
}

# The designated requirement TCC stores with each grant must be exactly the
# pinned identity, in every architecture, for the app and its nested code.
verify_release_signature() {
    local bundle="$1"
    local actual
    actual="$(codesign -d -r- "${bundle}" 2>/dev/null | sed -n 's/^#* *designated => //p')"
    if [ "${actual}" != "${EXPECTED_DESIGNATED_REQUIREMENT}" ]; then
        echo "ERROR: unexpected designated requirement for ${bundle#"${PROJECT_DIR}"/}" >&2
        echo "  expected: ${EXPECTED_DESIGNATED_REQUIREMENT}" >&2
        echo "  actual:   ${actual:-none}" >&2
        exit 1
    fi
    require_signature "${bundle}" "${EXPECTED_DESIGNATED_REQUIREMENT}"
    local nested
    for nested in \
        "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "Contents/Frameworks/Sparkle.framework/Versions/B" \
        "Contents/Frameworks/MediaRemoteAdapter.framework" \
        "Contents/Helpers/whytap"; do
        if [ -e "${bundle}/${nested}" ]; then
            require_signature "${bundle}/${nested}" "${SIGNER_REQUIREMENT}"
        fi
    done
}

detach_dmg_mount() {
    local mount_point="$1"
    local attempts="${2:-6}"

    if [ -z "${mount_point}" ] || [ ! -d "${mount_point}" ]; then
        return 0
    fi

    for attempt in $(seq 1 "${attempts}"); do
        if hdiutil detach "${mount_point}" -force >/dev/null 2>&1; then
            return 0
        fi
        sync
        sleep "${attempt}"
    done

    echo "ERROR: failed to detach ${mount_point} after ${attempts} attempts." >&2
    hdiutil detach "${mount_point}" -force
}

echo "▶ Flavor: ${FLAVOR}"
echo "▶ Bundle: ${APP_BUNDLE_NAME}.app  id=${BUNDLE_ID}"
echo "▶ Version: ${SHORT_VERSION}  build=${BUILD_VERSION}"

# --- Pre-flight checks ----------------------------------------------------

echo "▶ Pre-flight checks..."

if [ ! -f "${INFO_PLIST_TEMPLATE}" ]; then
    echo "ERROR: Info.plist template missing at ${INFO_PLIST_TEMPLATE}" >&2
    exit 1
fi

if [ ! -f "${SPARKLE_PUBKEY_FILE}" ]; then
    echo "ERROR: Sparkle public key missing at ${SPARKLE_PUBKEY_FILE}" >&2
    echo "Bootstrap: ./scripts/sparkle-keys-bootstrap.sh" >&2
    exit 1
fi

# Meeting Notes BlockNote viewer bundle (Stage 8a). Committed to the repo
# under Resources/blocknote/ so this check should rarely trip on a clean
# checkout; if it does, the developer needs Node installed to regenerate.
if [ ! -f "${PROJECT_DIR}/Resources/blocknote/index.html" ]; then
    echo "ERROR: BlockNote bundle missing at Resources/blocknote/index.html" >&2
    echo "Run: bash scripts/build-blocknote.sh" >&2
    exit 1
fi

# Sparkle's EdDSA public key is base64-encoded ed25519 (32 bytes → 44 chars
# with padding, sometimes 43 without). Reject anything else early — a stray
# newline or whitespace silently breaks Info.plist substitution downstream.
SPARKLE_PUBLIC_ED_KEY="$(tr -d '\n\r ' < "${SPARKLE_PUBKEY_FILE}")"
if ! [[ "${SPARKLE_PUBLIC_ED_KEY}" =~ ^[A-Za-z0-9+/=]{43,44}$ ]]; then
    echo "ERROR: Sparkle public key in ${SPARKLE_PUBKEY_FILE} has invalid format." >&2
    echo "Expected: 43-44 chars base64 (single line, no whitespace)." >&2
    echo "Got: ${SPARKLE_PUBLIC_ED_KEY}" >&2
    exit 1
fi

# Check layout dependencies/background before compiling or accessing signing keys.
/usr/bin/python3 "${DMG_LAYOUT}" preflight --background-source "${DMG_BACKGROUND_SRC}"

# --- Toolchain guard: require the macOS 26 (Tahoe) SDK -------------------
# WHY: on macOS 26 AppKit applies the Liquid Glass material pipeline only to
# binaries linked against the macOS 26 SDK. An Xcode 16.x toolchain links the
# macOS 15 SDK, so the DMG renders legacy (pre-Liquid Glass) materials on
# Tahoe — the island's glass looked wrong on a teammate's fresh install vs
# local dev builds (Xcode 26.4.1). The release used to pin this via a GitHub
# `macos-26` runner + `xcode-select -s /Applications/Xcode_26`; with the CI
# build gone, local releases enforce the same SDK floor here.
# (Pinned by ReleaseToolchainContractTests.)
# WHY: docs/decisions/2026-06-19-tahoe-sdk-guard-local-release.md
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if ! [[ "${SDK_MAJOR}" =~ ^[0-9]+$ ]] || [ "${SDK_MAJOR}" -lt 26 ]; then
    echo "ERROR: release requires the macOS 26 (Tahoe) SDK, found SDK '${SDK_VERSION:-unknown}'." >&2
    echo "Select an Xcode 26.x toolchain: sudo xcode-select -s /Applications/Xcode_26.app" >&2
    echo "WHY: Xcode 16.x links the macOS 15 SDK → legacy (pre-Liquid Glass) materials on Tahoe." >&2
    exit 1
fi

if [ "${LEGACY_SIGNED_RELEASE}" = "1" ]; then
    if ! security find-identity -v -p codesigning | grep -qE "Developer ID Application:.*\(${TEAM_ID}\)"; then
        echo "ERROR: Developer ID cert not found in Keychain." >&2
        echo "Install via Xcode -> Settings -> Accounts -> Manage Certificates -> + Developer ID Application." >&2
        exit 1
    fi

    missing_env=()
    [ -z "${ASC_API_KEY_ID:-}" ]        && missing_env+=("ASC_API_KEY_ID")
    [ -z "${ASC_API_KEY_ISSUER_ID:-}" ] && missing_env+=("ASC_API_KEY_ISSUER_ID")
    [ -z "${ASC_API_KEY_P8:-}" ]        && missing_env+=("ASC_API_KEY_P8")
    if [ ${#missing_env[@]} -gt 0 ]; then
        echo "ERROR: missing required env vars: ${missing_env[*]}" >&2
        echo "Run via 'doppler run --project sidekey --config dev -- ./scripts/build-dmg.sh'" >&2
        exit 1
    fi

fi

if [ -n "${SIGNING_CERTIFICATE_FILE}" ]; then
    SIGNING_CERTIFICATE_TEXT="$(/usr/bin/openssl x509 -in "${SIGNING_CERTIFICATE_FILE}" -noout -text 2>/dev/null || true)"
    if [[ "${SIGNING_CERTIFICATE_TEXT}" != *"Code Signing"* ]]; then
        echo "ERROR: ${SIGNING_CERTIFICATE_FILE#"${PROJECT_DIR}"/} is not a PEM code-signing certificate." >&2
        exit 1
    fi
    SIGNING_CERTIFICATE_SHA1="$(/usr/bin/openssl x509 -in "${SIGNING_CERTIFICATE_FILE}" -noout -fingerprint -sha1 \
        | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"
    if ! [[ "${SIGNING_CERTIFICATE_SHA1}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: could not read the SHA-1 of ${SIGNING_CERTIFICATE_FILE#"${PROJECT_DIR}"/}." >&2
        exit 1
    fi
    CODE_SIGNING="certificate:${SIGNING_CERTIFICATE_SHA1}"
    EXPECTED_DESIGNATED_REQUIREMENT="identifier \"${BUNDLE_ID}\" and certificate leaf = H\"${SIGNING_CERTIFICATE_SHA1}\""
    SIGNER_REQUIREMENT="certificate leaf = H\"${SIGNING_CERTIFICATE_SHA1}\""
fi
if [ -n "${SIGNING_TEAM_ID}" ]; then
    # The default requirement codesign records for a Developer ID Application
    # certificate: any certificate the team holds now or after renewal matches.
    CODE_SIGNING="team:${SIGNING_TEAM_ID}"
    EXPECTED_DESIGNATED_REQUIREMENT="identifier \"${BUNDLE_ID}\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ${SIGNING_TEAM_ID}"
    SIGNER_REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"${SIGNING_TEAM_ID}\""
    # A secure timestamp keeps these signatures valid after the certificate expires.
    SIGNING_TIMESTAMP_ARGS=(--timestamp)
fi
echo "▶ Code signing: ${CODE_SIGNING}"
NOTARIZATION="none"
if [ "${NOTARIZE}" = "1" ]; then
    # Apple notarizes only code signed with a Developer ID certificate.
    if [ "${LEGACY_SIGNED_RELEASE}" = "0" ] && [ -z "${SIGNING_TEAM_ID}" ]; then
        echo "ERROR: EXODIA_NOTARIZE=1 needs the Developer ID team in Resources/developer-id-team.txt;" >&2
        echo "community-certificate and ad-hoc builds cannot be notarized." >&2
        exit 1
    fi
    NOTARIZATION="notarized"
    if [ "${NOTARY_CREDENTIALS}" = "case" ]; then
        echo "▶ Notarization: Apple notary service, key from Whytap Case project ${NOTARY_CASE_PROJECT}"
    else
        echo "▶ Notarization: Apple notary service, key from the environment (legacy mode)"
    fi
fi

if [ "${PREFLIGHT_ONLY}" -eq 1 ]; then
    SIGNING_KEY_CONFIGURED=0
    if [ -n "${EXODIA_COMMUNITY_SIGNING_KEY:-}" ] || [ -n "${EXODIA_COMMUNITY_SIGNING_KEY_FILE:-}" ]; then
        SIGNING_KEY_CONFIGURED=1
    fi
    NOTARY_SOURCE=""
    if [ "${NOTARIZE}" = "1" ] && [ "${NOTARY_CREDENTIALS}" = "case" ]; then
        NOTARY_SOURCE="case:${NOTARY_CASE_PROJECT}"
    elif [ "${NOTARIZE}" = "1" ]; then
        NOTARY_SOURCE="environment"
    fi
    /usr/bin/python3 - "${DISTRIBUTION_MODE}" "${BUNDLE_ID}" "${SHORT_VERSION}" "${BUILD_VERSION}" \
        "${CODE_SIGNING}" "${SIGNING_KEY_CONFIGURED}" "${NOTARIZATION}" "${NOTARY_SOURCE}" \
        "${NOTARY_KEYS}" <<'PYJSON'
import json, sys
mode, bundle_id, version, build, code_signing, key_configured, notarization, notary_source, notary_keys = sys.argv[1:]
certificate = code_signing.split(":", 1)[1] if code_signing.startswith("certificate:") else None
team = code_signing.split(":", 1)[1] if code_signing.startswith("team:") else None
print(json.dumps({"distribution": mode, "bundle_id": bundle_id,
    "version": version, "build": int(build), "architectures": ["arm64", "x86_64"],
    "code_signing": code_signing, "signing_certificate_sha1": certificate,
    "signing_team_id": team,
    "signing_key_configured": key_configured == "1",
    "requires_apple_developer": mode == "developer-id" or team is not None,
    "requires_notarization": notarization == "notarized",
    "notarization": notarization,
    "notarization_credentials": notary_source or None,
    "notarization_keys": notary_keys.split(",") if notary_source else []}))
PYJSON
    exit 0
fi

# Team mode signs with the team's Developer ID certificate from the login
# keychain; find it before compiling so a missing certificate fails fast.
if [ -n "${SIGNING_TEAM_ID}" ]; then
    DEVELOPER_ID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"Developer ID Application: .* (${SIGNING_TEAM_ID})\"\$/\1/p" \
        | sort -u || true)"
    if [ -n "${EXODIA_DEVELOPER_ID_IDENTITY:-}" ]; then
        SIGNING_IDENTITY="$(printf '%s' "${EXODIA_DEVELOPER_ID_IDENTITY}" | tr 'a-f' 'A-F')"
        if ! printf '%s\n' "${DEVELOPER_ID_IDENTITIES}" | grep -qx "${SIGNING_IDENTITY}"; then
            echo "ERROR: EXODIA_DEVELOPER_ID_IDENTITY is not a valid Developer ID Application identity of team ${SIGNING_TEAM_ID}." >&2
            exit 1
        fi
    else
        case "$(printf '%s' "${DEVELOPER_ID_IDENTITIES}" | grep -c . || true)" in
            1) SIGNING_IDENTITY="${DEVELOPER_ID_IDENTITIES}" ;;
            0)
                echo "ERROR: no valid Developer ID Application certificate of team ${SIGNING_TEAM_ID} in the keychain." >&2
                echo "Install it via Xcode -> Settings -> Accounts -> Manage Certificates, or set" >&2
                echo "EXODIA_COMMUNITY_SIGNING=adhoc for a local ad-hoc build that cannot be published." >&2
                exit 1
                ;;
            *)
                echo "ERROR: several Developer ID Application certificates of team ${SIGNING_TEAM_ID};" >&2
                echo "choose one with EXODIA_DEVELOPER_ID_IDENTITY=<SHA-1>." >&2
                exit 1
                ;;
        esac
    fi
    echo "▶ Developer ID identity: ${SIGNING_IDENTITY}"
fi

# Certificate mode needs the matching private key; check it before compiling.
if [ -n "${SIGNING_CERTIFICATE_SHA1}" ]; then
    if [ -z "${EXODIA_COMMUNITY_SIGNING_KEY:-}" ] && [ -z "${EXODIA_COMMUNITY_SIGNING_KEY_FILE:-}" ]; then
        echo "ERROR: certificate signing needs EXODIA_COMMUNITY_SIGNING_KEY or EXODIA_COMMUNITY_SIGNING_KEY_FILE." >&2
        echo "Run via 'doppler run --project sidekey --config dev -- ./scripts/build-dmg.sh', or set" >&2
        echo "EXODIA_COMMUNITY_SIGNING=adhoc for a local ad-hoc build that cannot be published." >&2
        exit 1
    fi
    if [ -n "${EXODIA_COMMUNITY_SIGNING_KEY_FILE:-}" ] && [ ! -f "${EXODIA_COMMUNITY_SIGNING_KEY_FILE}" ]; then
        echo "ERROR: EXODIA_COMMUNITY_SIGNING_KEY_FILE is not a file." >&2
        exit 1
    fi
    CERTIFICATE_PUBLIC_KEY="$(/usr/bin/openssl x509 -in "${SIGNING_CERTIFICATE_FILE}" -noout -pubkey)"
    SIGNING_KEY_PUBLIC_KEY="$(community_signing_key | /usr/bin/openssl pkey -passin pass: -pubout 2>/dev/null || true)"
    if [ -z "${SIGNING_KEY_PUBLIC_KEY}" ] || [ "${SIGNING_KEY_PUBLIC_KEY}" != "${CERTIFICATE_PUBLIC_KEY}" ]; then
        echo "ERROR: the community signing key does not match ${SIGNING_CERTIFICATE_FILE#"${PROJECT_DIR}"/}." >&2
        exit 1
    fi
fi

# Notarization needs Apple's tools and, for team builds, the API key in Case.
# Check both before compiling; only key names are read here, never values.
if [ "${NOTARIZE}" = "1" ]; then
    if ! xcrun notarytool --version >/dev/null 2>&1; then
        echo "ERROR: notarization needs xcrun notarytool (Xcode command-line tools)." >&2
        exit 1
    fi
fi
if [ "${NOTARIZE}" = "1" ] && [ "${NOTARY_CREDENTIALS}" = "case" ]; then
    if [ ! -x "${CASE_HELPER}" ]; then
        echo "ERROR: notarization reads the App Store Connect API key from Whytap Case," >&2
        echo "but its command is missing: ${CASE_HELPER}" >&2
        echo "Install Whytap in /Applications or set EXODIA_CASE_HELPER to its Contents/Helpers/whytap." >&2
        exit 1
    fi
    case_status=0
    CASE_KEY_NAMES="$("${CASE_HELPER}" case ls -p "${NOTARY_CASE_PROJECT}" 2>/dev/null \
        | awk '{ print $1 }')" || case_status=$?
    if [ "${case_status}" -ne 0 ]; then
        echo "ERROR: Whytap Case could not list project ${NOTARY_CASE_PROJECT} (exit ${case_status})." >&2
        echo "Open Whytap, unlock Case and allow this client, then rebuild." >&2
        exit 1
    fi
    missing_keys=()
    for key_name in ${NOTARY_KEYS//,/ }; do
        if ! printf '%s\n' "${CASE_KEY_NAMES}" | grep -qx "${key_name}"; then
            missing_keys+=("${key_name}")
        fi
    done
    if [ "${#missing_keys[@]}" -gt 0 ]; then
        echo "ERROR: notarization needs an App Store Connect API key in Whytap Case project ${NOTARY_CASE_PROJECT}." >&2
        echo "Missing keys: ${missing_keys[*]}" >&2
        echo "Create a team key with the Developer role (App Store Connect -> Users and Access ->" >&2
        echo "Integrations -> Team Keys), then add its Key ID as ASC_API_KEY_ID, the Issuer ID as" >&2
        echo "ASC_API_KEY_ISSUER_ID and the contents of AuthKey_<key ID>.p8 as ASC_API_KEY_P8." >&2
        echo "See docs/build-and-release.md (Apple notarization)." >&2
        exit 1
    fi
    echo "▶ Notarization key found in Whytap Case project ${NOTARY_CASE_PROJECT}"
fi

# Pin the clean build-input commit before compiling; sealing checks it again.
BUILD_SOURCE_SHA="$(/usr/bin/python3 "${PROJECT_DIR}/scripts/release-provenance.py" capture \
    --project-root "${PROJECT_DIR}")"

# --- Secrets staging (private umask, mktemp, trap cleanup) ----------------
# The notarization key is staged by notarize-submit.sh in its own process.

SIGNING_DIR=""
SIGNING_KEYCHAIN=""

cleanup() {
    if [ -n "${SIGNING_KEYCHAIN:-}" ] && [ -f "${SIGNING_KEYCHAIN}" ]; then
        security delete-keychain "${SIGNING_KEYCHAIN}" >/dev/null 2>&1 || true
    fi
    if [ -n "${SIGNING_DIR:-}" ] && [ -d "${SIGNING_DIR}" ]; then
        wipe_file "${SIGNING_DIR}/key.pem"
        wipe_file "${SIGNING_DIR}/identity.p12"
        rm -rf "${SIGNING_DIR}"
    fi
    if [ -n "${DMG_ROOT:-}" ] && [ -d "${DMG_ROOT}" ]; then
        rm -rf "${DMG_ROOT}"
    fi
    # Detach any leftover staging mount so a re-run is not blocked by a
    # stale "Volume X" entry in /Volumes.
    if [ -n "${DMG_MOUNT_POINT:-}" ] && [ -d "${DMG_MOUNT_POINT}" ]; then
        detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
    fi
    if [ -n "${DMG_RW_PATH:-}" ] && [ -f "${DMG_RW_PATH}" ]; then
        rm -f "${DMG_RW_PATH}"
    fi
    rm -f "${APP_ZIP}"
}
trap cleanup EXIT

# $1 = archive to submit: the zipped app or the signed DMG.
notarize_archive() {
    local status=0
    if [ "${NOTARY_CREDENTIALS}" = "case" ]; then
        # Case puts the key into this one command's environment only. The
        # command is single-quoted; its own shell expands the paths below.
        EXODIA_NOTARY_SUBMIT="${PROJECT_DIR}/scripts/notarize-submit.sh" \
        EXODIA_NOTARY_ARCHIVE="$1" \
        EXODIA_NOTARY_LOG_DIR="${PROJECT_DIR}/build" \
            "${CASE_HELPER}" case run -p "${NOTARY_CASE_PROJECT}" --only "${NOTARY_KEYS}" \
            '/bin/bash "$EXODIA_NOTARY_SUBMIT" "$EXODIA_NOTARY_ARCHIVE" "$EXODIA_NOTARY_LOG_DIR"' \
            || status=$?
    else
        /bin/bash "${PROJECT_DIR}/scripts/notarize-submit.sh" "$1" "${PROJECT_DIR}/build" || status=$?
    fi
    if [ "${status}" -ne 0 ]; then
        echo "ERROR: notarization of ${1##*/} failed (exit ${status}); see the messages above." >&2
        exit 1
    fi
}

# $1 = notarized path; the remaining arguments select the assessment type.
require_notarized_assessment() {
    local target="$1" output status=0
    shift
    output="$(spctl --assess -vv "$@" "${target}" 2>&1)" || status=$?
    if [ "${status}" -ne 0 ] || [[ "${output}" != *"source=Notarized Developer ID"* ]]; then
        echo "ERROR: Gatekeeper does not accept ${target##*/} as notarized:" >&2
        printf '%s\n' "${output}" >&2
        exit 1
    fi
    printf '%s\n' "${output}" | sed 's/^/  /'
}

# --- Build ---------------------------------------------------------------

mkdir -p "${PROJECT_DIR}/build"

echo "▶ Building release binary (${FLAVOR}, universal x86_64+arm64)..."
cd "${PROJECT_DIR}"
# Universal build: build each architecture with SwiftPM's native build system,
# then lipo the two executables. This began as a workaround for MLX's Metal
# kernels, which left with the on-device models; it stays the proven release
# path. WHY: docs/decisions/2026-06-29-universal-release-native-backend-lipo.md
# --product Sidekey: build only the consumer line — the B2B executable
# has its own build path and must never ride along into a user release.
# shellcheck disable=SC2086 # SWIFT_FLAGS expands to multi-token "-Xswiftc -DBETA" intentionally.
swift build --build-system native -c release --arch arm64 --product Sidekey ${SWIFT_FLAGS}
# shellcheck disable=SC2086 # SWIFT_FLAGS expands to multi-token "-Xswiftc -DBETA" intentionally.
swift build --build-system native -c release --arch x86_64 --product Sidekey ${SWIFT_FLAGS}
# Case secrets helper (Contents/Helpers/whytap): same flags and both arches.
# shellcheck disable=SC2086
swift build --build-system native -c release --arch arm64 --product whytap ${SWIFT_FLAGS}
# shellcheck disable=SC2086
swift build --build-system native -c release --arch x86_64 --product whytap ${SWIFT_FLAGS}

echo "▶ Resolving native products dirs..."
# shellcheck disable=SC2086 # SWIFT_FLAGS expands to multi-token intentionally.
ARM64_BUILD_DIR="$(swift build --build-system native -c release --arch arm64 ${SWIFT_FLAGS} --show-bin-path)"
# shellcheck disable=SC2086 # SWIFT_FLAGS expands to multi-token intentionally.
X86_64_BUILD_DIR="$(swift build --build-system native -c release --arch x86_64 ${SWIFT_FLAGS} --show-bin-path)"
if [ -z "${ARM64_BUILD_DIR}" ] || [ ! -d "${ARM64_BUILD_DIR}" ]; then
    echo "ERROR: arm64 swift build --show-bin-path returned an unusable path: '${ARM64_BUILD_DIR}'" >&2
    exit 1
fi
if [ -z "${X86_64_BUILD_DIR}" ] || [ ! -d "${X86_64_BUILD_DIR}" ]; then
    echo "ERROR: x86_64 swift build --show-bin-path returned an unusable path: '${X86_64_BUILD_DIR}'" >&2
    exit 1
fi
echo "  arm64 products dir: ${ARM64_BUILD_DIR}"
echo "  x86_64 products dir: ${X86_64_BUILD_DIR}"

if [ ! -f "${ARM64_BUILD_DIR}/${EXECUTABLE_NAME}" ]; then
    echo "ERROR: expected arm64 executable ${EXECUTABLE_NAME} not found in ${ARM64_BUILD_DIR}." >&2
    exit 1
fi
if [ ! -f "${X86_64_BUILD_DIR}/${EXECUTABLE_NAME}" ]; then
    echo "ERROR: expected x86_64 executable ${EXECUTABLE_NAME} not found in ${X86_64_BUILD_DIR}." >&2
    exit 1
fi

BUILD_DIR="${PROJECT_DIR}/build/release-universal"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
echo "▶ Creating universal executable with lipo..."
lipo -create \
    "${ARM64_BUILD_DIR}/${EXECUTABLE_NAME}" \
    "${X86_64_BUILD_DIR}/${EXECUTABLE_NAME}" \
    -output "${BUILD_DIR}/${EXECUTABLE_NAME}"
lipo -create \
    "${ARM64_BUILD_DIR}/whytap" \
    "${X86_64_BUILD_DIR}/whytap" \
    -output "${BUILD_DIR}/whytap"
HELPER_LIPO_INFO="$(lipo -info "${BUILD_DIR}/whytap")"
case "${HELPER_LIPO_INFO}" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *)
        echo "ERROR: whytap helper is not universal (need x86_64 + arm64)." >&2
        echo "  lipo -info: ${HELPER_LIPO_INFO}" >&2
        exit 1
        ;;
esac
echo "  products dir: ${BUILD_DIR}"

if [ ! -f "${BUILD_DIR}/${EXECUTABLE_NAME}" ]; then
    echo "ERROR: expected executable ${EXECUTABLE_NAME} not found in ${BUILD_DIR}." >&2
    exit 1
fi

# Note: pre-#NN the release build also compiled `Sources/Sidekey/OrbShader.metal`
# into `Sidekey_Sidekey.bundle/default.metallib` (xcbuild auto-rule, with an
# `xcrun metal` + `metallib` fallback for runners that lacked the Metal
# toolchain). The orb is now drawn with SwiftUI `Shape`s — no shader, no
# SwiftPM resource bundle, no metallib. Runtime assets below are copied as
# normal app resources.

# Static verification: the built executable MUST contain both x86_64 and
# arm64 slices. If lipo reports only one, the multi-arch build silently
# fell through to a single-arch slice (e.g. an SDK that did not link both
# targets) — fail before code-signing rather than ship a non-universal DMG.
echo "▶ Verifying executable is universal (x86_64 + arm64)..."
EXEC_LIPO_INFO="$(lipo -info "${BUILD_DIR}/${EXECUTABLE_NAME}")"
echo "  ${EXEC_LIPO_INFO}"
if ! echo "${EXEC_LIPO_INFO}" | grep -q 'x86_64' \
   || ! echo "${EXEC_LIPO_INFO}" | grep -q 'arm64'; then
    echo "ERROR: ${EXECUTABLE_NAME} is not a universal binary." >&2
    echo "  lipo -info: ${EXEC_LIPO_INFO}" >&2
    echo "  expected: both x86_64 and arm64 architectures present." >&2
    exit 1
fi

echo "▶ Creating app bundle ${APP_BUNDLE_NAME}.app..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Executable name stays "Sidekey" (matches Package.swift target). The .app
# wrapper carries the flavor name; CFBundleExecutable in the plist also
# stays "Sidekey".
cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# Case secrets helper: the broker pins this binary's cdhash, so it must be
# signed with the app's identity below and never modified afterwards.
mkdir -p "${APP_BUNDLE}/Contents/Helpers"
cp "${BUILD_DIR}/whytap" "${APP_BUNDLE}/Contents/Helpers/whytap"
chmod 755 "${APP_BUNDLE}/Contents/Helpers/whytap"

# SwiftPM can carry the active Xcode toolchain's Swift library directory into
# LC_RPATH. That directory exists only on the build Mac and makes macOS's
# distribution assessment reject otherwise valid embedded frameworks. Keep
# only system and bundle-relative search paths, before signing either slice.
RELEASE_RPATHS="$(otool -l "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" | \
    awk '/cmd LC_RPATH/ { rpath = 1; next } rpath && /path / { sub(/^ *path /, ""); sub(/ \(offset.*$/, ""); print; rpath = 0 }' | sort -u)"
while IFS= read -r release_rpath; do
    case "${release_rpath}" in
        ""|/usr/lib/*|/System/Library/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*) ;;
        *)
            echo "▶ Removing build-machine rpath: ${release_rpath}"
            install_name_tool -delete_rpath "${release_rpath}" \
                "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
            ;;
    esac
done <<< "${RELEASE_RPATHS}"

# CRITICAL: SwiftPM does not embed @executable_path/../Frameworks in the
# binary's rpath search list. Without it, dyld cannot resolve the
# @rpath/Sparkle.framework/Versions/B/Sparkle install name at launch and
# the app crashes immediately on every install. Add the rpath here, before
# any codesign step touches the main executable, so the later main-app
# codesign signs the already-patched binary in one pass.
echo "▶ Adding @executable_path/../Frameworks to binary rpath..."
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

echo "▶ Generating Info.plist from template..."
sed -e "s|__BUNDLE_ID__|${BUNDLE_ID}|g" \
    -e "s|__BUNDLE_DISPLAY_NAME__|${BUNDLE_DISPLAY_NAME}|g" \
    -e "s|__BUNDLE_EXECUTABLE__|${EXECUTABLE_NAME}|g" \
    -e "s|__BUNDLE_ICON_FILE__|${BUNDLE_ICON_FILE}|g" \
    -e "s|__SHORT_VERSION__|${SHORT_VERSION}|g" \
    -e "s|__BUILD_VERSION__|${BUILD_VERSION}|g" \
    -e "s|__APPCAST_URL__|${APPCAST_URL}|g" \
    -e "s|__SPARKLE_PUBLIC_ED_KEY__|${SPARKLE_PUBLIC_ED_KEY}|g" \
    "${INFO_PLIST_TEMPLATE}" > "${APP_BUNDLE}/Contents/Info.plist"
python3 "${PROJECT_DIR}/scripts/configure-calendar-clients.py" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ExodiaDistribution string ${DISTRIBUTION_MODE}" \
    "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ExodiaSourceRevision string ${BUILD_SOURCE_SHA}" \
    "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ExodiaInstanceLeaseVersion integer 1" \
    "${APP_BUNDLE}/Contents/Info.plist"

if [ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -f "${MENU_BAR_ICON}" ]; then
    cp "${MENU_BAR_ICON}" "${APP_BUNDLE}/Contents/Resources/MenuBarIconTemplate.pdf"
fi

# Useful Links chip icons — bundled provider logos plus globe fallback,
# loaded by `UsefulLinkIconAsset` from Bundle.main at runtime. Mirror the
# dev-run.sh copy so the production .app bundle keeps the same shape.
USEFUL_LINK_ICONS_DIR="${PROJECT_DIR}/Resources/UsefulLinkIcons"
if [ -d "${USEFUL_LINK_ICONS_DIR}" ]; then
    cp -R "${USEFUL_LINK_ICONS_DIR}" "${APP_BUNDLE}/Contents/Resources/UsefulLinkIcons"
fi

# Language picker flag PNGs. Mirror dev-run.sh so production DMGs carry
# the same matte flag assets used by the Dynamic Island language picker.
LANGUAGE_FLAGS_DIR="${PROJECT_DIR}/Resources/LanguageFlags"
if [ -d "${LANGUAGE_FLAGS_DIR}" ]; then
    cp -R "${LANGUAGE_FLAGS_DIR}" "${APP_BUNDLE}/Contents/Resources/LanguageFlags"
fi

# Custom fonts (Instrument Serif) for editorial display typography.
# Mirror dev-run.sh — registered automatically via Info.plist
# ATSApplicationFontsPath = "Fonts".
FONTS_DIR="${PROJECT_DIR}/Resources/Fonts"
if [ -d "${FONTS_DIR}" ]; then
    cp -R "${FONTS_DIR}" "${APP_BUNDLE}/Contents/Resources/Fonts"
fi

# Orb actions overlay icons (round 3) — Agent / Drop / Clipboard PDFs.
# Mirror dev-run.sh so the production .app carries the same files.
for icon in orb-icon-agent orb-icon-drop copy-icon-neon; do
    if [ -f "${PROJECT_DIR}/Resources/${icon}.pdf" ]; then
        cp "${PROJECT_DIR}/Resources/${icon}.pdf" "${APP_BUNDLE}/Contents/Resources/${icon}.pdf"
    fi
done

# Dynamic Island hover-panel control orbs — bundled PDFs converted from
# Maxim's hand-drawn SVGs in `svg v2/` via `rsvg-convert -f pdf`. Loaded
# by `IslandControlIcon.image(named:)`. Mirror dev-run.sh so beta + prod
# DMGs carry the same icon set. Older `orb-icon-*.pdf` / `copy-icon-neon.pdf`
# above remain — they're still consumed by the floating-orb hover panel.
for icon in \
    island-clipboard \
    island-drop-fast \
    island-drop-smart \
    island-exit \
    island-language \
    island-language-ring \
    island-memory \
    island-settings \
    island-vocab; do
    if [ -f "${PROJECT_DIR}/Resources/${icon}.pdf" ]; then
        cp "${PROJECT_DIR}/Resources/${icon}.pdf" "${APP_BUNDLE}/Contents/Resources/${icon}.pdf"
    fi
done

# Meeting Notes BlockNote bundle (Stage 8a) — HTML+JS+CSS loaded by the
# Meetings viewer's WKWebView via a file:// URL pointed at the .app's
# Contents/Resources/blocknote/. Mirror dev-run.sh so beta + prod DMGs
# carry the bundle identically.
BLOCKNOTE_BUNDLE_DIR="${PROJECT_DIR}/Resources/blocknote"
if [ -d "${BLOCKNOTE_BUNDLE_DIR}" ]; then
    cp -R "${BLOCKNOTE_BUNDLE_DIR}" "${APP_BUNDLE}/Contents/Resources/blocknote"
fi

# --- Bundle the MediaRemote adapter (prompt-free Now Playing source) ----
#
# Vendored under Resources/MediaRemoteAdapter/ (ungive/mediaremote-adapter,
# BSD-3, pinned commit — see THIRD_PARTY_NOTICE.md). Two artifacts:
#   * run.pl  → Contents/Resources/MediaRemoteAdapter/run.pl  (a plain perl
#     script; sealed as a Resource by the final app sign, no own codesign).
#   * MediaRemoteAdapter.framework → Contents/Frameworks/  (the dlopen target
#     the perl driver loads; signed below before the app sign).
# Hard-fail if either is missing: a partial bundle would silently degrade to
# the AppleScript fallback on every machine, which is exactly the failure this
# pivot removes. The framework MUST be universal (mirror the Sparkle check).
MRA_SRC="${PROJECT_DIR}/Resources/MediaRemoteAdapter"
MRA_PL_SRC="${MRA_SRC}/run.pl"
MRA_FW_SRC="${MRA_SRC}/MediaRemoteAdapter.framework"
if [ ! -f "${MRA_PL_SRC}" ] || [ ! -d "${MRA_FW_SRC}" ]; then
    echo "ERROR: MediaRemote adapter assets missing under Resources/MediaRemoteAdapter/." >&2
    echo "  expected: run.pl and MediaRemoteAdapter.framework" >&2
    exit 1
fi

echo "▶ Bundling MediaRemoteAdapter (run.pl + framework)..."
mkdir -p "${APP_BUNDLE}/Contents/Resources/MediaRemoteAdapter"
cp "${MRA_PL_SRC}" "${APP_BUNDLE}/Contents/Resources/MediaRemoteAdapter/run.pl"
chmod 0644 "${APP_BUNDLE}/Contents/Resources/MediaRemoteAdapter/run.pl"

mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
rm -rf "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"
ditto "${MRA_FW_SRC}" "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"

MRA_FW_BIN="${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
if [ ! -f "${MRA_FW_BIN}" ]; then
    echo "ERROR: MediaRemoteAdapter framework binary missing at ${MRA_FW_BIN}." >&2
    exit 1
fi
echo "▶ Verifying MediaRemoteAdapter.framework is universal (x86_64 + arm64)..."
MRA_LIPO_INFO="$(lipo -info "${MRA_FW_BIN}")"
echo "  ${MRA_LIPO_INFO}"
if ! echo "${MRA_LIPO_INFO}" | grep -q 'x86_64' \
   || ! echo "${MRA_LIPO_INFO}" | grep -q 'arm64'; then
    echo "ERROR: bundled MediaRemoteAdapter.framework is not universal." >&2
    echo "  lipo -info: ${MRA_LIPO_INFO}" >&2
    echo "  expected: both x86_64 and arm64." >&2
    exit 1
fi

# --- Embed Sparkle.framework -------------------------------------------

echo "▶ Embedding Sparkle.framework..."
SPARKLE_FRAMEWORK_SRC="$(find "${PROJECT_DIR}/.build" -name 'Sparkle.framework' -type d -path '*/Sparkle.xcframework/*' | head -1)"
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ]; then
    # Fall back to any Sparkle.framework if the xcframework path didn't match.
    SPARKLE_FRAMEWORK_SRC="$(find "${PROJECT_DIR}/.build" -name 'Sparkle.framework' -type d | head -1)"
fi
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ]; then
    echo "ERROR: Sparkle.framework not found in .build/." >&2
    echo "Run 'swift build -c release' first to fetch the Sparkle artifact bundle." >&2
    exit 1
fi
echo "  source: ${SPARKLE_FRAMEWORK_SRC}"

mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
ditto "${SPARKLE_FRAMEWORK_SRC}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

SPARKLE_BUNDLE="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B"

# Static verification: the embedded Sparkle binary MUST also be universal,
# otherwise the main executable can be universal but the framework would
# only load on one arch — silently breaking auto-update on the other.
# Sparkle ships the macos-arm64_x86_64 slice as a fat binary in its
# xcframework, so this check is a regression guard against a future
# upstream layout change.
echo "▶ Verifying Sparkle.framework is universal (x86_64 + arm64)..."
SPARKLE_BIN="${SPARKLE_BUNDLE}/Sparkle"
if [ ! -f "${SPARKLE_BIN}" ]; then
    echo "ERROR: Sparkle binary missing at ${SPARKLE_BIN}." >&2
    exit 1
fi
SPARKLE_LIPO_INFO="$(lipo -info "${SPARKLE_BIN}")"
echo "  ${SPARKLE_LIPO_INFO}"
if ! echo "${SPARKLE_LIPO_INFO}" | grep -q 'x86_64' \
   || ! echo "${SPARKLE_LIPO_INFO}" | grep -q 'arm64'; then
    echo "ERROR: embedded Sparkle.framework is not universal." >&2
    echo "  lipo -info: ${SPARKLE_LIPO_INFO}" >&2
    echo "  expected: both x86_64 and arm64 in Sparkle's macOS slice." >&2
    exit 1
fi

# Pre-flight: every Sparkle 2.x bundle ships these helpers. If anything is
# missing, the SwiftPM artifact bundle is corrupt or its layout changed in
# an incompatible way — better to fail here than to ship a broken update
# pipeline.
for required in \
    "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc" \
    "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc" \
    "${SPARKLE_BUNDLE}/Autoupdate" \
    "${SPARKLE_BUNDLE}/Updater.app"; do
    if [ ! -e "${required}" ]; then
        echo "ERROR: Sparkle framework missing required helper: ${required}" >&2
        echo "  (artifact bundle may have changed in a new Sparkle version — review release notes)" >&2
        exit 1
    fi
done

# --- Codesign Sparkle helpers + framework + app -------------------------
#
# Sparkle 2 requires signing each helper explicitly, deepest first, before
# signing the framework and app. Do NOT use codesign --deep — it can't apply
# distinct entitlement options per nested bundle, which Sparkle's XPCs need.
# Sequence follows https://sparkle-project.org/documentation/sandboxing
# ("Manually Re-sign Sparkle XPC Services").
#
# Per the official docs: Installer.xpc must NOT use --preserve-metadata=entitlements
# (it has no embedded entitlements that would survive); Downloader.xpc MUST,
# because Sparkle bundles sandbox entitlements into Downloader that our app
# entitlements would otherwise overwrite.

SIGNING_ARGS=(--sign "${SIGNING_IDENTITY}")
if [ -n "${SIGNING_CERTIFICATE_SHA1}" ]; then
    # A private keychain outside the user's search list holds the identity only
    # while signing; cleanup() deletes it and wipes the staged key material.
    echo "▶ Importing the community signing identity into a temporary keychain..."
    ORIGINAL_UMASK="$(umask)"
    umask 077
    SIGNING_DIR="$(mktemp -d -t exodia-signing)"
    SIGNING_KEYCHAIN="${SIGNING_DIR}/signing.keychain-db"
    community_signing_key > "${SIGNING_DIR}/key.pem"
    SIGNING_KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
    EXODIA_SIGNING_P12_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
    export EXODIA_SIGNING_P12_PASSWORD
    /usr/bin/openssl pkcs12 -export -inkey "${SIGNING_DIR}/key.pem" -in "${SIGNING_CERTIFICATE_FILE}" \
        -name "Exodia Community Code Signing" -out "${SIGNING_DIR}/identity.p12" \
        -passin pass: -passout env:EXODIA_SIGNING_P12_PASSWORD
    wipe_file "${SIGNING_DIR}/key.pem"
    umask "${ORIGINAL_UMASK}"
    security create-keychain -p "${SIGNING_KEYCHAIN_PASSWORD}" "${SIGNING_KEYCHAIN}"
    security set-keychain-settings -lut 3600 "${SIGNING_KEYCHAIN}"
    security unlock-keychain -p "${SIGNING_KEYCHAIN_PASSWORD}" "${SIGNING_KEYCHAIN}"
    security import "${SIGNING_DIR}/identity.p12" -k "${SIGNING_KEYCHAIN}" \
        -P "${EXODIA_SIGNING_P12_PASSWORD}" -f pkcs12 -T /usr/bin/codesign >/dev/null
    wipe_file "${SIGNING_DIR}/identity.p12"
    unset EXODIA_SIGNING_P12_PASSWORD
    security set-key-partition-list -S apple-tool:,apple: -s -k "${SIGNING_KEYCHAIN_PASSWORD}" \
        "${SIGNING_KEYCHAIN}" >/dev/null
    SIGNING_IDENTITIES="$(security find-identity -p codesigning "${SIGNING_KEYCHAIN}")"
    if [[ "${SIGNING_IDENTITIES}" != *"$(printf '%s' "${SIGNING_CERTIFICATE_SHA1}" | tr 'a-f' 'A-F')"* ]]; then
        echo "ERROR: the community certificate is not usable as a code-signing identity." >&2
        exit 1
    fi
    SIGNING_ARGS=(--sign "${SIGNING_CERTIFICATE_SHA1}" --keychain "${SIGNING_KEYCHAIN}")
fi

echo "▶ Code signing whytap helper..."
codesign --force \
    "${SIGNING_ARGS[@]}" \
    --options runtime \
    "${SIGNING_TIMESTAMP_ARGS[@]}" \
    "${APP_BUNDLE}/Contents/Helpers/whytap"

echo "▶ Code signing Sparkle XPC services..."
if [ -d "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc" ]; then
    codesign --force \
        "${SIGNING_ARGS[@]}" \
        --options runtime \
        "${SIGNING_TIMESTAMP_ARGS[@]}" \
        "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc"
fi
if [ -d "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc" ]; then
    codesign --force \
        "${SIGNING_ARGS[@]}" \
        --options runtime \
        "${SIGNING_TIMESTAMP_ARGS[@]}" \
        --preserve-metadata=entitlements \
        "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc"
fi

if [ -f "${SPARKLE_BUNDLE}/Autoupdate" ]; then
    echo "▶ Code signing Sparkle Autoupdate helper..."
    codesign --force \
        "${SIGNING_ARGS[@]}" \
        --options runtime \
        "${SIGNING_TIMESTAMP_ARGS[@]}" \
        "${SPARKLE_BUNDLE}/Autoupdate"
fi

if [ -d "${SPARKLE_BUNDLE}/Updater.app" ]; then
    echo "▶ Code signing Sparkle Updater.app helper..."
    codesign --force \
        "${SIGNING_ARGS[@]}" \
        --options runtime \
        "${SIGNING_TIMESTAMP_ARGS[@]}" \
        "${SPARKLE_BUNDLE}/Updater.app"
fi

echo "▶ Code signing Sparkle.framework..."
codesign --force \
    "${SIGNING_ARGS[@]}" \
    --options runtime \
    "${SIGNING_TIMESTAMP_ARGS[@]}" \
    "${SPARKLE_BUNDLE}"

# Sign the MediaRemote adapter framework before the app sign (deepest-first,
# no --deep). The perl driver dlopens it; with the hardened runtime +
# disable-library-validation entitlement on the app, a normally-signed
# framework loads (notarization-allowed). The final app sign seals run.pl as
# a Resource, and the `codesign --verify --deep --strict` below validates the
# nested framework.
echo "▶ Code signing MediaRemoteAdapter.framework..."
codesign --force \
    "${SIGNING_ARGS[@]}" \
    --options runtime \
    "${SIGNING_TIMESTAMP_ARGS[@]}" \
    "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"

echo "▶ Code signing app bundle..."
# No --deep — Sparkle helpers and framework are already signed individually.
codesign \
    --force \
    "${SIGNING_ARGS[@]}" \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    "${SIGNING_TIMESTAMP_ARGS[@]}" \
    "${APP_BUNDLE}"

echo "▶ Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
if [ -n "${SIGNER_REQUIREMENT}" ]; then
    verify_release_signature "${APP_BUNDLE}"
    echo "  ok: designated requirement ${EXPECTED_DESIGNATED_REQUIREMENT}"
fi
otool -L "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" | grep -i sparkle || {
    echo "ERROR: app binary does not link against Sparkle.framework" >&2
    exit 1
}
if [ "${LEGACY_SIGNED_RELEASE}" = "1" ]; then
    spctl --assess --type exec --verbose "${APP_BUNDLE}" 2>&1 || \
        echo "  (warning: spctl assess returned non-zero — expected before notarize/staple)"
fi

# Static smoke: verify rpath chain without launching the app.
# A runtime DYLD check (DYLD_PRINT_LIBRARIES on a launched binary) requires
# an interactive UI session for menu-bar apps (`.accessory` activation policy) with NSStatusItem
# — it fails on headless macOS runners (no loginwindow), because the
# app exits before dyld emits a successful Sparkle load line.
# Three static signals together give equivalent confidence:
#   1. binary's LC_RPATH list contains @executable_path/../Frameworks
#      (proves the install_name_tool -add_rpath step above actually applied)
#   2. binary links @rpath/Sparkle.framework/Versions/B/Sparkle
#      (already verified above via `otool -L | grep -i sparkle`)
#   3. Sparkle.framework binary exists at that path inside the bundle
#      (resolves the @rpath chain at runtime on the user's machine)
echo "▶ Static rpath verification..."

# 1. Check @executable_path/../Frameworks is in the LC_RPATH list.
if ! otool -l "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" \
        | grep -A2 LC_RPATH \
        | grep -q "@executable_path/../Frameworks"; then
    echo "ERROR: @executable_path/../Frameworks missing from binary rpath." >&2
    echo "  install_name_tool -add_rpath step earlier must have failed silently." >&2
    exit 1
fi
echo "  ok: rpath @executable_path/../Frameworks present"

# 2. Verify the embedded framework exists at the expected path.
EMBEDDED_SPARKLE="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
if [ ! -f "${EMBEDDED_SPARKLE}" ]; then
    echo "ERROR: Sparkle.framework binary missing at expected location:" >&2
    echo "  ${EMBEDDED_SPARKLE}" >&2
    exit 1
fi
echo "  ok: Sparkle.framework binary present at ${EMBEDDED_SPARKLE#"${APP_BUNDLE}"/}"

# 3. (rpath link already verified above by `otool -L | grep sparkle` — keep that check)
echo "  ok: rpath chain @rpath/Sparkle... → @executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle (resolves at runtime)"

# macOS launch services, Gatekeeper, and Sparkle's helper launch path expect
# distributable bundles to have normal Unix permissions. Keep secret staging
# private, but ship apps as readable/traversable by all local users.
echo "▶ Normalizing bundle file permissions..."
find "${APP_BUNDLE}" -type d -exec chmod u+rwx,go+rx {} +
find "${APP_BUNDLE}" -type f -exec chmod u+rw,go+r {} +
chmod u+rwx,go+rx "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
find "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework" \
    \( -path "*/Contents/MacOS/*" -o -name "Autoupdate" -o -name "Sparkle" \) \
    -type f -exec chmod u+rwx,go+rx {} +

if find "${APP_BUNDLE}" -type d ! -perm -055 -print -quit | grep -q .; then
    echo "ERROR: app bundle contains a directory that is not world-readable/traversable." >&2
    exit 1
fi
if find "${APP_BUNDLE}" -type f ! -perm -044 -print -quit | grep -q .; then
    echo "ERROR: app bundle contains a file that is not world-readable." >&2
    exit 1
fi
if [ ! -x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" ]; then
    echo "ERROR: main executable is not executable." >&2
    exit 1
fi
echo "  ok: directories are +rx, files are +r, executables are +x"

echo "▶ Re-verifying signature after permission normalization..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

if [ "${NOTARIZE}" = "1" ]; then
    # --- Notarize app bundle ------------------------------------------------
    # The app carries its own stapled ticket, so a copy dragged out of the DMG
    # opens without Apple's servers; the DMG is notarized separately below.

    echo "▶ Zipping app bundle for notarization submission..."
    rm -f "${APP_ZIP}"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_ZIP}"
    notarize_archive "${APP_ZIP}"
    rm -f "${APP_ZIP}"

    echo "▶ Stapling notarization ticket to app bundle..."
    xcrun stapler staple "${APP_BUNDLE}"
    xcrun stapler validate "${APP_BUNDLE}"

    echo "▶ Gatekeeper assessment of the stapled app..."
    require_notarized_assessment "${APP_BUNDLE}" --type execute

    # macOS 14+ checks distribution-specific problems that spctl can miss, such
    # as external library search paths left behind by the developer toolchain.
    if command -v syspolicy_check >/dev/null 2>&1; then
        syspolicy_check distribution "${APP_BUNDLE}"
    fi

    # The ticket lives outside the signature seal; the requirement is unchanged.
    if [ -n "${SIGNER_REQUIREMENT}" ]; then
        verify_release_signature "${APP_BUNDLE}"
    fi
else
    echo "▶ Community build: Apple notarization and stapling are not used."
fi

# Load the shipped executable and frameworks without initializing user state.
# This catches missing runtime dependencies before anyone downloads the DMG.
"${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" --installation-check

# --- DMG packaging ------------------------------------------------------
#
# Create writable HFS+, write its Finder metadata directly, then compress.
# Layout is a release contract even in EXODIA_DMG_HEADLESS=1: no Finder session
# or Automation permission is needed. Verify again after the final remount.

echo "▶ Creating writable staging DMG..."
rm -f "${DMG_PATH}"
DMG_ROOT="$(mktemp -d -t sidekey-dmg-root)"
DMG_RW_PATH="${PROJECT_DIR}/build/${APP_BUNDLE_NAME}-staging-rw.dmg"
DMG_MOUNT_POINT="/Volumes/${BUNDLE_DISPLAY_NAME}"

ditto "${APP_BUNDLE}" "${DMG_ROOT}/${APP_BUNDLE_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

# The committed background and its layout are required for every archive.
mkdir -p "${DMG_ROOT}/.background"
cp "${DMG_BACKGROUND_SRC}" "${DMG_ROOT}/.background/background.png"

# Detach any stale mount from a previous failed run before reusing the
# volume name — otherwise hdiutil attach below picks a "<name> 1" path and
# the expected mount point would refer to a different volume.
if [ -d "${DMG_MOUNT_POINT}" ]; then
    detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
fi

# HFS+ + UDRW: writable while we write the layout, will be converted to
# compressed UDZO below before notarization.
rm -f "${DMG_RW_PATH}"
hdiutil create \
    -srcfolder "${DMG_ROOT}" \
    -volname "${BUNDLE_DISPLAY_NAME}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${DMG_RW_PATH}"

echo "▶ Mounting staging DMG read-write..."
hdiutil attach \
    -nobrowse \
    -readwrite \
    -noverify \
    -noautoopen \
    "${DMG_RW_PATH}" > /dev/null

# Sanity: the symlink the user is supposed to drag onto must actually be on
# the volume before writing the layout / converting. If the symlink is
# missing at this point, hdiutil silently dropped it from the srcfolder copy
# and continuing would ship a broken DMG.
if [ ! -L "${DMG_MOUNT_POINT}/Applications" ]; then
    echo "ERROR: Applications symlink missing from staging volume." >&2
    echo "  expected: ${DMG_MOUNT_POINT}/Applications -> /Applications" >&2
    detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
    exit 1
fi

echo "▶ Writing Finder window layout (offline, headless=${DMG_HEADLESS})..."
/usr/bin/python3 "${DMG_LAYOUT}" write \
    --volume "${DMG_MOUNT_POINT}" --app-name "${APP_BUNDLE_NAME}.app" \
    --background-source "${DMG_BACKGROUND_SRC}"

sync

echo "▶ Detaching staging DMG..."
detach_dmg_mount "${DMG_MOUNT_POINT}"

echo "▶ Converting staging UDRW → compressed UDZO..."
hdiutil convert \
    "${DMG_RW_PATH}" \
    -format UDZO \
    -ov \
    -o "${DMG_PATH}"
rm -f "${DMG_RW_PATH}"

# Post-create verification: mount the final UDZO read-only and confirm the
# /Applications symlink resolves correctly. This is the contract the user
# sees in Finder when they double-click the DMG.
echo "▶ Verifying Applications symlink in final DMG..."
if [ -d "${DMG_MOUNT_POINT}" ]; then
    detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
fi
hdiutil attach -nobrowse -readonly -noverify -noautoopen "${DMG_PATH}" > /dev/null
SYMLINK_OK=0
if [ -L "${DMG_MOUNT_POINT}/Applications" ] && \
   [ "$(readlink "${DMG_MOUNT_POINT}/Applications")" = "/Applications" ]; then
    SYMLINK_OK=1
fi
APP_PRESENT=0
if [ -d "${DMG_MOUNT_POINT}/${APP_BUNDLE_NAME}.app" ]; then
    APP_PRESENT=1
fi
# Read the final archive's records, positions and on-volume background alias.
# Missing/corrupt metadata must fail before signing, notarization or sealing.
/usr/bin/python3 "${DMG_LAYOUT}" verify \
    --volume "${DMG_MOUNT_POINT}" --app-name "${APP_BUNDLE_NAME}.app" \
    --background-source "${DMG_BACKGROUND_SRC}"
if [ -n "${SIGNER_REQUIREMENT}" ] && [ "${APP_PRESENT}" -eq 1 ]; then
    if ! (verify_release_signature "${DMG_MOUNT_POINT}/${APP_BUNDLE_NAME}.app"); then
        detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
        exit 1
    fi
    echo "  ok: ${APP_BUNDLE_NAME}.app in the DMG keeps the designated requirement"
fi
if [ "${NOTARIZE}" = "1" ] && [ "${APP_PRESENT}" -eq 1 ]; then
    if ! xcrun stapler validate "${DMG_MOUNT_POINT}/${APP_BUNDLE_NAME}.app" >/dev/null; then
        echo "ERROR: ${APP_BUNDLE_NAME}.app in the DMG lost its stapled notarization ticket." >&2
        detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
        exit 1
    fi
    echo "  ok: ${APP_BUNDLE_NAME}.app in the DMG keeps its stapled ticket"
fi
detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true

if [ "${SYMLINK_OK}" -ne 1 ]; then
    echo "ERROR: final DMG is missing the Applications -> /Applications symlink." >&2
    echo "  Users would see only the app icon without a drop target." >&2
    exit 1
fi
if [ "${APP_PRESENT}" -ne 1 ]; then
    echo "ERROR: final DMG is missing ${APP_BUNDLE_NAME}.app." >&2
    exit 1
fi
echo "  ok: Applications symlink + ${APP_BUNDLE_NAME}.app + verified Finder layout present in DMG"

# --- Codesign DMG -------------------------------------------------------

echo "▶ Code signing DMG..."
codesign \
    --force \
    "${SIGNING_ARGS[@]}" \
    "${SIGNING_TIMESTAMP_ARGS[@]}" \
    --identifier "${BUNDLE_ID}.dmg" \
    "${DMG_PATH}"
if [ -n "${SIGNER_REQUIREMENT}" ]; then
    require_signature "${DMG_PATH}" "identifier \"${BUNDLE_ID}.dmg\" and ${SIGNER_REQUIREMENT}"
fi

if [ "${NOTARIZE}" = "1" ]; then
    # --- Notarize DMG -------------------------------------------------------

    notarize_archive "${DMG_PATH}"

    echo "▶ Stapling notarization ticket to DMG..."
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"

    echo "▶ Gatekeeper assessment of the stapled DMG..."
    require_notarized_assessment "${DMG_PATH}" --type open --context context:primary-signature
fi

# Write the build-time receipt only after final archive bytes are complete.
/usr/bin/python3 "${PROJECT_DIR}/scripts/release-provenance.py" seal \
    --project-root "${PROJECT_DIR}" --source-sha "${BUILD_SOURCE_SHA}" \
    --archive "${DMG_PATH}" --version "${SHORT_VERSION}" --build "${BUILD_VERSION}" \
    --flavor "${FLAVOR}" --distribution "${DISTRIBUTION_MODE}" \
    --code-signing "${CODE_SIGNING}" --notarization "${NOTARIZATION}" >/dev/null

# --- Final ---------------------------------------------------------------

echo ""
if [ "${LEGACY_SIGNED_RELEASE}" = "1" ]; then
    echo "✓ Developer-ID signed + notarized DMG: ${DMG_PATH}"
elif [ -n "${SIGNING_TEAM_ID}" ] && [ "${NOTARIZE}" = "1" ]; then
    echo "✓ Notarized DMG (Developer ID team ${SIGNING_TEAM_ID}, app and DMG stapled): ${DMG_PATH}"
elif [ -n "${SIGNING_TEAM_ID}" ]; then
    echo "✓ Community DMG (Developer ID team ${SIGNING_TEAM_ID}, not Apple-notarized): ${DMG_PATH}"
elif [ -n "${SIGNING_CERTIFICATE_SHA1}" ]; then
    echo "✓ Community DMG (Whytap certificate ${SIGNING_CERTIFICATE_SHA1}, not Apple-notarized): ${DMG_PATH}"
else
    echo "✓ Community DMG (ad-hoc signed, not Apple-notarized): ${DMG_PATH}"
fi
