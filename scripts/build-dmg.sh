#!/bin/bash
#
# build-dmg.sh — Build, sign, notarize, staple, and package Whytap as DMG.
#
# Usage:
#   FLAVOR=beta|prod \
#   SHORT_VERSION=0.2.0 \
#   BUILD_VERSION=42 \
#     doppler run --project sidekey --config dev -- ./scripts/build-dmg.sh
#
# Env (all optional with defaults):
#   FLAVOR         beta|prod   (default: prod)
#   SHORT_VERSION  SemVer       (default: 0.2.0)
#   BUILD_VERSION  monotonic    (default: 1; user-release picks next live build)
#                  integer
#
# Requires:
#   - Apple Developer ID Application certificate in Keychain
#     (Xcode -> Settings -> Accounts -> Manage Certificates -> + Developer ID Application)
#   - Doppler env: ASC_API_KEY_ID, ASC_API_KEY_ISSUER_ID, ASC_API_KEY_P8
#
# Outputs:
#   - build/${APP_BUNDLE_NAME}-${SHORT_VERSION}-build${BUILD_VERSION}.dmg
#     where APP_BUNDLE_NAME = Whytap (prod) or Whytap-Beta (beta).

set -euo pipefail

# --- Flavor parameterisation ---------------------------------------------

FLAVOR="${FLAVOR:-prod}"
SHORT_VERSION="${SHORT_VERSION:-0.2.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"

if ! [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
    echo "ERROR: BUILD_VERSION must be an integer (got: '${BUILD_VERSION}')" >&2
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

TEAM_ID="${TEAM_ID:?set TEAM_ID to your Apple Developer Team ID (Developer ID Application certificate)}"
SIGNING_IDENTITY="${TEAM_ID}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# BUILD_DIR points at the staged universal executable produced below. The
# release build intentionally avoids `swift build --arch arm64 --arch x86_64`:
# that multi-arch invocation switches SwiftPM to the Xcode build backend, which
# tries to compile MLX's generated .metal resources even though we ship the
# prebuilt, version-locked Resources/mlx.metallib.
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
MENU_BAR_ICON="${PROJECT_DIR}/Resources/MenuBarIconTemplate.pdf"

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

# MLX Metal shader library (ROO-257). Committed to the repo as a build artifact
# (like AppIcon.icns / blocknote/) because `swift build` cannot compile Metal
# shaders. Without it, on-device LLM inference throws "Failed to load the
# default metallib" at runtime. Hard-fail at release time: shipping a DMG whose
# Local LLM silently can't run is a worse outcome than blocking the build.
# (arm64-only is expected — MLX / Local LLM is Apple-Silicon-gated.)
#
# Delegate to `build-metallib.sh --check` rather than re-implementing the
# validation here: it asserts the lib exists, is a valid MetalLib, AND is
# version-locked to the current Package.resolved mlx-swift revision (via the
# committed .revision sidecar). The version lock is the safety net — an MLX bump
# that forgets to regenerate the metallib would otherwise build/sign/notarize a
# DMG whose GPU kernels mismatch the runtime and crash on the first local-LLM op.
# Same hard-fail philosophy as the BlockNote / Sparkle pre-flight checks above.
if ! bash "${PROJECT_DIR}/scripts/build-metallib.sh" --check; then
    echo "ERROR: MLX metallib pre-flight failed (missing, invalid, or stale vs Package.resolved)." >&2
    echo "Run: bash scripts/build-metallib.sh   (regenerates the lib + version-lock sidecar)" >&2
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

if ! xcrun notarytool --version >/dev/null 2>&1; then
    echo "ERROR: xcrun notarytool not available. Install Xcode 13+ (or Command Line Tools)." >&2
    exit 1
fi

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

# --- Secrets staging (private umask, mktemp, trap cleanup) ----------------

ORIGINAL_UMASK="$(umask)"
umask 077
ASC_KEY_DIR="$(mktemp -d -t sidekey-asc)"

cleanup() {
    if [ -n "${ASC_KEY_DIR:-}" ] && [ -d "${ASC_KEY_DIR}" ]; then
        rm -rf "${ASC_KEY_DIR}"
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

ASC_KEY_PATH="${ASC_KEY_DIR}/AuthKey.p8"
printf '%s' "${ASC_API_KEY_P8}" > "${ASC_KEY_PATH}"
umask "${ORIGINAL_UMASK}"

# --- Build ---------------------------------------------------------------

mkdir -p "${PROJECT_DIR}/build"

echo "▶ Building release binary (${FLAVOR}, universal x86_64+arm64)..."
cd "${PROJECT_DIR}"
# Universal build: build each architecture with SwiftPM's native build system,
# then lipo the two executables. A single multi-arch `swift build` switches to
# the Xcode build backend and attempts to compile MLX's generated .metal files;
# this app ships the prebuilt Resources/mlx.metallib instead.
# WHY: docs/decisions/2026-06-29-universal-release-native-backend-lipo.md
# --product Sidekey: build only the consumer line — the B2B executable
# has its own build path and must never ride along into a user release.
# shellcheck disable=SC2086 # SWIFT_FLAGS expands to multi-token "-Xswiftc -DBETA" intentionally.
swift build --build-system native -c release --arch arm64 --product Sidekey ${SWIFT_FLAGS}
# shellcheck disable=SC2086 # SWIFT_FLAGS expands to multi-token "-Xswiftc -DBETA" intentionally.
swift build --build-system native -c release --arch x86_64 --product Sidekey ${SWIFT_FLAGS}

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

# CRITICAL: SwiftPM does not embed @executable_path/../Frameworks in the
# binary's rpath search list. Without it, dyld cannot resolve the
# @rpath/Sparkle.framework/Versions/B/Sparkle install name at launch and
# the app crashes immediately on every install. Add the rpath here, before
# any codesign step touches the main executable, so the later main-app
# codesign signs the already-patched binary in one pass.
echo "▶ Adding @executable_path/../Frameworks to binary rpath..."
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# --- Bundle the MLX Metal shader library (sealed RESOURCE + symlink) -------
# MLX (on-device LLM, ROO-257) resolves its precompiled GPU kernels by trying,
# in order (device.cpp load_default_library): <binary_dir>/mlx.metallib, then
# <binary_dir>/Resources/mlx.metallib. The binary lives in Contents/MacOS, so
# the colocated path is Contents/MacOS/mlx.metallib.
#
# We deliberately do NOT ship the metallib as a real file under Contents/MacOS/.
# A .metallib is a non-Mach-O "generic" object: codesign cannot embed a
# signature, so signing it leaves a DETACHED signature in the
# com.apple.cs.CodeSignature xattr and records it as a nested *code* item that
# carries no stapled notarization ticket of its own. On macOS 15 (Sequoia) the
# quarantined first-launch Gatekeeper path then tries to confirm that
# un-stapleable nested code object ONLINE; when that lookup is blocked/slow
# (e.g. Apple endpoints unreachable from some networks) the launch hard-fails
# with "Apple could not verify … is free of malware" even though spctl and
# `codesign --verify` pass locally. macOS 26 (Tahoe) honored the outer ticket
# and never exhibited this. (Codename for what broke: first MLX release 1.15.0.)
#
# Fix: ship the metallib as an ordinary SEALED RESOURCE in Contents/Resources/
# (hashed into _CodeSignature/CodeResources by the final app sign — no detached
# xattr, no separate online-notarization surface) and put a RELATIVE symlink at
# Contents/MacOS/mlx.metallib -> ../Resources/mlx.metallib so MLX's colocated
# loader still finds it. The relative symlink survives app translocation and is
# sealed by the app signature. The committed Resources/mlx.metallib is produced
# by scripts/build-metallib.sh and version-locked to the resolved mlx-swift
# revision — bump MLX ⇒ re-run build-metallib.sh.
# WHY: docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md
echo "▶ Bundling MLX metallib (Contents/Resources/mlx.metallib + MacOS symlink)..."
cp "${PROJECT_DIR}/Resources/mlx.metallib" "${APP_BUNDLE}/Contents/Resources/mlx.metallib"
ln -s "../Resources/mlx.metallib" "${APP_BUNDLE}/Contents/MacOS/mlx.metallib"

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

# Custom fonts (Instrument Serif) for the native SwiftUI onboarding.
# Mirror dev-run.sh — registered automatically via Info.plist
# ATSApplicationFontsPath = "Fonts".
FONTS_DIR="${PROJECT_DIR}/Resources/Fonts"
if [ -d "${FONTS_DIR}" ]; then
    cp -R "${FONTS_DIR}" "${APP_BUNDLE}/Contents/Resources/Fonts"
fi

# Onboarding voice samples. Loaded by `OnboardingAudioResources` from
# Bundle.main/OnboardingAudio so beta + prod DMGs match the preview's audible
# Drop + Agent demos without relying on SwiftPM resource bundles in a signed
# .app wrapper.
ONBOARDING_AUDIO_DIR="${PROJECT_DIR}/Resources/OnboardingAudio"
if [ -d "${ONBOARDING_AUDIO_DIR}" ]; then
    cp -R "${ONBOARDING_AUDIO_DIR}" "${APP_BUNDLE}/Contents/Resources/OnboardingAudio"
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

echo "▶ Code signing Sparkle XPC services..."
if [ -d "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc" ]; then
    codesign --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc"
fi
if [ -d "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc" ]; then
    codesign --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        --preserve-metadata=entitlements \
        "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc"
fi

if [ -f "${SPARKLE_BUNDLE}/Autoupdate" ]; then
    echo "▶ Code signing Sparkle Autoupdate helper..."
    codesign --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        "${SPARKLE_BUNDLE}/Autoupdate"
fi

if [ -d "${SPARKLE_BUNDLE}/Updater.app" ]; then
    echo "▶ Code signing Sparkle Updater.app helper..."
    codesign --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        "${SPARKLE_BUNDLE}/Updater.app"
fi

echo "▶ Code signing Sparkle.framework..."
codesign --force \
    --sign "${SIGNING_IDENTITY}" \
    --options runtime \
    --timestamp \
    "${SPARKLE_BUNDLE}"

# Sign the MediaRemote adapter framework before the app sign (deepest-first,
# no --deep). The perl driver dlopens it; with the hardened runtime +
# disable-library-validation entitlement on the app, a normally-signed
# framework loads (notarization-allowed). The final app sign seals run.pl as
# a Resource, and the `codesign --verify --deep --strict` below validates the
# nested framework.
echo "▶ Code signing MediaRemoteAdapter.framework..."
codesign --force \
    --sign "${SIGNING_IDENTITY}" \
    --options runtime \
    --timestamp \
    "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"

# NB: the MLX metallib is intentionally NOT signed here. It ships as a sealed
# RESOURCE at Contents/Resources/mlx.metallib (hashed into CodeResources by the
# app sign below) with a relative symlink at Contents/MacOS/mlx.metallib.
# Signing it separately would make it a nested code item with a detached,
# un-stapleable signature — the exact Sequoia first-launch Gatekeeper failure
# this layout fixes (see the bundling step above). WHY:
# docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md

echo "▶ Code signing app bundle..."
# No --deep — Sparkle helpers and framework are already signed individually.
codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    --timestamp \
    "${APP_BUNDLE}"

echo "▶ Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
otool -L "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" | grep -i sparkle || {
    echo "ERROR: app binary does not link against Sparkle.framework" >&2
    exit 1
}
spctl --assess --type exec --verbose "${APP_BUNDLE}" 2>&1 || \
    echo "  (warning: spctl assess returned non-zero — expected before notarize/staple)"

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

# --- Notarize app bundle ------------------------------------------------

echo "▶ Zipping app bundle for notarization submission..."
rm -f "${APP_ZIP}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_ZIP}"

echo "▶ Submitting app bundle to Apple notarization (this may take a few minutes)..."
# --timeout 1200 (= 20 min) hard-caps the --wait poll. When Apple's notary
# queue stalls (observed May 2026: 18–30 h waits), notarytool exits non-zero
# at 20 min instead of leaving a local release attempt stuck indefinitely.
# On a healthy queue this submission finishes in well under 5 min, so the cap
# is never hit during normal operation. The submission continues server-side
# even after timeout; the next local release attempt will re-submit and
# usually succeed.
if ! xcrun notarytool submit "${APP_ZIP}" \
        --key "${ASC_KEY_PATH}" \
        --key-id "${ASC_API_KEY_ID}" \
        --issuer "${ASC_API_KEY_ISSUER_ID}" \
        --wait \
        --timeout 1200; then
    echo "ERROR: notarytool submit failed for app bundle." >&2
    echo "Inspect log via:" >&2
    echo "  xcrun notarytool history --key '${ASC_KEY_PATH}' --key-id '${ASC_API_KEY_ID}' --issuer '${ASC_API_KEY_ISSUER_ID}'" >&2
    echo "  xcrun notarytool log <submission-id> --key '${ASC_KEY_PATH}' --key-id '${ASC_API_KEY_ID}' --issuer '${ASC_API_KEY_ISSUER_ID}' --output-format json" >&2
    exit 1
fi

echo "▶ Stapling notarization ticket to app bundle..."
xcrun stapler staple "${APP_BUNDLE}"
xcrun stapler validate "${APP_BUNDLE}"

# Verify Gatekeeper acceptance of stapled app bundle
if ! spctl --assess --type execute --verbose=2 "${APP_BUNDLE}"; then
    echo "ERROR: Gatekeeper rejected the notarized app; refusing to package it." >&2
    exit 1
fi

# Load the shipped executable and frameworks without initializing user state.
# This catches missing runtime dependencies before anyone downloads the DMG.
"${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" --installation-check

# --- DMG packaging ------------------------------------------------------
#
# Two-step build:
#   1. Build a writable UDRW image from the staging dir (app bundle + symlink
#      to /Applications). HFS+ is required so Finder can persist its window
#      layout via .DS_Store inside the volume.
#   2. Mount UDRW, run AppleScript to paint a "drag here" Finder window
#      (icon view, hidden toolbar, app on the left, /Applications on the
#      right). AppleScript is best-effort: in headless CI without a UI
#      session the Finder calls may no-op, but the symlink and contents are
#      already on disk at the file-system level, so the install UX is still
#      correct (just without polished icon positions).
#   3. Detach, convert UDRW to compressed UDZO for distribution.
#   4. Mount the final UDZO read-only and assert the symlink survived —
#      hard fail with a clear error otherwise so a broken DMG never ships.

echo "▶ Creating writable staging DMG..."
rm -f "${DMG_PATH}"
DMG_ROOT="$(mktemp -d -t sidekey-dmg-root)"
DMG_RW_PATH="${PROJECT_DIR}/build/${APP_BUNDLE_NAME}-staging-rw.dmg"
DMG_MOUNT_POINT="/Volumes/${BUNDLE_DISPLAY_NAME}"

ditto "${APP_BUNDLE}" "${DMG_ROOT}/${APP_BUNDLE_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

# Stage the drag-to-install background image in a hidden `.background/` folder
# inside the volume. The AppleScript below references it via a POSIX path; the
# folder is hidden so it doesn't show up in the user's Finder window. Treat the
# background as polish — if the source PNG is missing (e.g. a developer hasn't
# re-generated it after pulling), warn and continue. The DMG remains functional
# without it; only the visual hint is lost.
if [ -f "${DMG_BACKGROUND_SRC}" ]; then
    mkdir -p "${DMG_ROOT}/.background"
    cp "${DMG_BACKGROUND_SRC}" "${DMG_ROOT}/.background/background.png"
    echo "  ok: staged DMG background image (.background/background.png)"
else
    echo "  warn: DMG background image missing at ${DMG_BACKGROUND_SRC}" >&2
    echo "  (regenerate with: python3 scripts/generate-dmg-background.py)" >&2
    echo "  (continuing without background — DMG will use Finder default)" >&2
fi

# Detach any stale mount from a previous failed run before reusing the
# volume name — otherwise hdiutil attach below picks a "<name> 1" path and
# the AppleScript "tell disk <name>" call cannot find the volume.
if [ -d "${DMG_MOUNT_POINT}" ]; then
    detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
fi

# HFS+ + UDRW: writable while we paint the layout, will be converted to
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
# the volume before we hand it to AppleScript / convert. If the symlink is
# missing at this point, hdiutil silently dropped it from the srcfolder copy
# and continuing would ship a broken DMG.
if [ ! -L "${DMG_MOUNT_POINT}/Applications" ]; then
    echo "ERROR: Applications symlink missing from staging volume." >&2
    echo "  expected: ${DMG_MOUNT_POINT}/Applications -> /Applications" >&2
    detach_dmg_mount "${DMG_MOUNT_POINT}" 3 >/dev/null 2>&1 || true
    exit 1
fi

echo "▶ Painting Finder window layout (icon view, drag-to-install)..."
# AppleScript runs against a live Finder session. In a logged-in macOS
# session this is reliable; on a headless CI runner without a UI session
# the Finder bridge may not be reachable. The layout is polish — if the
# script no-ops, the DMG still mounts correctly with the symlink and the
# background.png is already on disk in .background/. Capture failures as a
# warning rather than a hard error.
#
# Window bounds {x0, y0, x1, y1} = {400, 100, 1060, 540} → 660x440 window,
# matching the logical icon coordinates used in generate-dmg-background.py
# (icons centred on y=220, Sidekey at x=180, Applications at x=480) so the
# rendered arrow sits between the two icons.
APPLESCRIPT_LOG="$(mktemp -t sidekey-dmg-layout)"
if osascript - "${BUNDLE_DISPLAY_NAME}" "${APP_BUNDLE_NAME}" <<'OSA' >"${APPLESCRIPT_LOG}" 2>&1; then
on run argv
    set volName to item 1 of argv
    set appName to (item 2 of argv) & ".app"
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set sidebar width of container window to 0
            set the bounds of container window to {400, 100, 1060, 540}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            -- Background image is staged in .background/ on the volume. Use a
            -- POSIX file path so the AppleScript "file" specifier doesn't have
            -- to navigate Finder's HFS-colon path syntax — Finder accepts
            -- POSIX paths for the background picture as of macOS 10.11+.
            try
                set background picture of viewOptions to POSIX file ("/Volumes/" & volName & "/.background/background.png")
            on error errMsg
                log "background picture set failed: " & errMsg
            end try
            set position of item appName of container window to {180, 220}
            set position of item "Applications" of container window to {480, 220}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
OSA
    echo "  ok: Finder layout applied"
else
    echo "  warn: Finder layout script returned non-zero (headless CI?)" >&2
    echo "  output (first 20 lines):" >&2
    head -20 "${APPLESCRIPT_LOG}" >&2 || true
    echo "  (continuing — symlink + contents + .background/ already on disk, layout is polish)" >&2
fi
rm -f "${APPLESCRIPT_LOG}"

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
# Background image present iff the source PNG existed at staging time. Track
# both the "expected" and "actual" state so the post-mount check matches what
# we actually staged — a missing source PNG is a warn at stage time, not a
# hard failure at verify time.
BACKGROUND_OK=0
if [ -f "${DMG_MOUNT_POINT}/.background/background.png" ]; then
    BACKGROUND_OK=1
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
if [ -f "${DMG_BACKGROUND_SRC}" ] && [ "${BACKGROUND_OK}" -ne 1 ]; then
    # Background was staged but did not survive the UDRW → UDZO conversion.
    # That's a real regression in the packaging step — fail rather than ship
    # a DMG without the drag-to-install hint that the source PNG advertises.
    echo "ERROR: final DMG is missing .background/background.png even though" >&2
    echo "  the source PNG was staged. The hdiutil convert step dropped it." >&2
    exit 1
fi
echo "  ok: Applications symlink + ${APP_BUNDLE_NAME}.app present in DMG"
if [ "${BACKGROUND_OK}" -eq 1 ]; then
    echo "  ok: .background/background.png present in DMG"
else
    echo "  note: .background/background.png NOT in DMG (source PNG was missing at stage time)"
fi

# --- Codesign DMG -------------------------------------------------------

echo "▶ Code signing DMG..."
codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --timestamp \
    --identifier "${BUNDLE_ID}.dmg" \
    "${DMG_PATH}"

# --- Notarize DMG -------------------------------------------------------

echo "▶ Submitting DMG to Apple notarization..."
# --timeout 1200: same rationale as the app-bundle submission above. See
# comment there for full context on why the cap matters.
if ! xcrun notarytool submit "${DMG_PATH}" \
        --key "${ASC_KEY_PATH}" \
        --key-id "${ASC_API_KEY_ID}" \
        --issuer "${ASC_API_KEY_ISSUER_ID}" \
        --wait \
        --timeout 1200; then
    echo "ERROR: notarytool submit failed for DMG." >&2
    echo "Inspect log via:" >&2
    echo "  xcrun notarytool history --key '${ASC_KEY_PATH}' --key-id '${ASC_API_KEY_ID}' --issuer '${ASC_API_KEY_ISSUER_ID}'" >&2
    echo "  xcrun notarytool log <submission-id> --key '${ASC_KEY_PATH}' --key-id '${ASC_API_KEY_ID}' --issuer '${ASC_API_KEY_ISSUER_ID}' --output-format json" >&2
    exit 1
fi

echo "▶ Stapling notarization ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

# --- Final ---------------------------------------------------------------

echo ""
echo "✓ Signed + notarized DMG: ${DMG_PATH}"
echo ""
echo "Verify Gatekeeper acceptance:"
echo "  spctl --assess --type install ${DMG_PATH}"
