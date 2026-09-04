#!/bin/bash
#
# dev-run.sh — Build (and optionally launch) Whytap as a stable .app bundle
# for local development.
#
# Why this exists:
#   `swift run` produces a bare Mach-O binary at .build/debug/Sidekey with an
#   adhoc signature whose cdhash changes every rebuild. macOS TCC keys
#   permissions (Accessibility, Microphone) by code identity,
#   so each adhoc rebuild can look like a new app and previously granted
#   permissions are silently invalidated. Symptoms: hotkey freezes, repeated
#   permission prompts, paste stops working.
#
#   This script builds a proper .app bundle with a stable path and signs it
#   together with the project entitlements. When a local "Sidekey Dev" signing
#   identity exists, we use it so the designated requirement stays stable
#   across rebuilds; otherwise the script falls back to adhoc signing.
#
# Difference from build-dmg.sh:
#   - Debug build (swift build, not -c release)
#   - Local dev signature ("Sidekey Dev") when available, not Developer ID
#   - No notarization, no DMG packaging
#   - Output at build/Whytap-Beta-dev.app to avoid colliding with release bundle
#
# Usage:
#   ./scripts/dev-run.sh                # build dev app (beta flavor)
#   ./scripts/dev-run.sh --run          # build then launch
#   ./scripts/dev-run.sh --onboarding   # build, launch, force the onboarding flow
#
# There is only one dev flavor (= beta bundle id + beta appcast).
# Production builds go through scripts/build-dmg.sh (release pipeline +
# Developer ID).
#
# If TCC permissions still get reset after using this script:
#   Re-grant once in System Settings → Privacy & Security
#   (Accessibility / Microphone). After that the signed
#   identity is stable and grants persist across rebuilds.

set -euo pipefail

# Configuration — single dev flavor (= beta bundle id / appcast). Bundle id
# is kept on `com.rootwise.sidekey.beta` so previously granted TCC
# permissions on the dev install keep working.
APP_NAME="Sidekey"
# SwiftPM (native build backend) names the built binary after the PRODUCT
# ("Sidekey" — thin executable target SidekeyApp wrapping the shared
# library; see Package.swift), so the artifact stays .build/debug/Sidekey.
EXECUTABLE_NAME="Sidekey"
APP_BUNDLE_NAME="Whytap-Beta-dev.app"
BUNDLE_ID="com.rootwise.sidekey.beta"
BUNDLE_DISPLAY_NAME="Whytap Beta"
BUNDLE_ICON_FILE="AppIcon"
DEV_APPCAST_URL="${DEV_APPCAST_URL:-https://github.com/${GITHUB_REPO:-AbsoluteMode/whytap}/releases/download/beta/appcast.xml}"
SWIFT_BUILD_ARGS=(--product Sidekey -Xswiftc -DBETA -Xswiftc -DSIDEKEY_FILE_TOKEN_STORE)
# Build/version values used only for the dev bundle's Info.plist. A high
# CFBundleVersion stops Sparkle from "discovering" a prod release as a
# downgrade should the dev bundle ever talk to the appcast.
DEV_SHORT_VERSION="0.0.0-dev"
DEV_BUILD_VERSION="9999"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/debug"
APP_BUNDLE="${PROJECT_DIR}/build/${APP_BUNDLE_NAME}"
ENTITLEMENTS="${PROJECT_DIR}/Resources/Sidekey.entitlements"
INFO_PLIST_TEMPLATE="${PROJECT_DIR}/Resources/Info.plist.template"
SPARKLE_PUBKEY_FILE="${PROJECT_DIR}/Resources/sparkle-public-ed-key.txt"
APP_ICON="${PROJECT_DIR}/Resources/AppIcon.icns"
MENU_BAR_ICON="${PROJECT_DIR}/Resources/MenuBarIconTemplate.pdf"

REQUESTED_SIGN_IDENTITY="${SIDEKEY_DEV_CODE_SIGN_IDENTITY:-Sidekey Dev}"
if [ "${REQUESTED_SIGN_IDENTITY}" = "-" ]; then
    SIGN_IDENTITY="-"
    SIGN_LABEL="adhoc"
elif security find-identity -v -p codesigning | grep -Fq "\"${REQUESTED_SIGN_IDENTITY}\""; then
    SIGN_IDENTITY="${REQUESTED_SIGN_IDENTITY}"
    SIGN_LABEL="${REQUESTED_SIGN_IDENTITY}"
else
    SIGN_IDENTITY="-"
    SIGN_LABEL="adhoc (missing ${REQUESTED_SIGN_IDENTITY})"
fi

# Dev appcast points at the selected flavor feed so Sparkle has a valid URL to
# parse. The high DEV_BUILD_VERSION above guarantees no real release will be
# served as a "newer" version.

# Parse args
RUN_AFTER_BUILD=0
LAUNCH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --run|-r)
            RUN_AFTER_BUILD=1
            ;;
        --onboarding)
            RUN_AFTER_BUILD=1
            LAUNCH_ARGS+=("--force-onboarding")
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Usage: $0 [--run|-r] [--onboarding]" >&2
            exit 2
            ;;
    esac
done

stop_conflicting_sidekey_processes() {
    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
        case "${command}" in
            */Contents/MacOS/${EXECUTABLE_NAME}*)
                bundle_path="${command%%/Contents/MacOS/${EXECUTABLE_NAME}*}"
                bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${bundle_path}/Contents/Info.plist" 2>/dev/null || true)"
                if [ "${bundle_id}" = "${BUNDLE_ID}" ]; then
                    echo "▶ Stopping existing ${BUNDLE_DISPLAY_NAME} dev process (${pid}, ${bundle_path})..."
                    kill "${pid}" 2>/dev/null || true
                fi
                ;;
        esac
    done < <(pgrep -x "${EXECUTABLE_NAME}" 2>/dev/null || true)
}

mkdir -p "${PROJECT_DIR}/build"

echo "▶ Building dev debug binary (swift build)..."
cd "${PROJECT_DIR}"
swift build "${SWIFT_BUILD_ARGS[@]}"

if [ ! -f "${BUILD_DIR}/${APP_NAME}" ]; then
    echo "✗ Expected binary not found at ${BUILD_DIR}/${APP_NAME}" >&2
    exit 1
fi

# Note: pre-#NN the dev build also compiled `Sources/Sidekey/OrbShader.metal`
# via `xcrun metal` + `metallib` into the SPM resource bundle, then dittoed
# that bundle into Contents/Resources/. The orb is now drawn with SwiftUI
# `Shape`s — no shader, no SwiftPM resource bundle, no metallib. Runtime
# assets below are copied as normal app resources.

echo "▶ Assembling app bundle at build/${APP_BUNDLE_NAME}..."
# Clean up old dev bundles so stale pre-rebrand apps do not linger in build/
# and accidentally launch with the same bundle identifier.
rm -rf "${PROJECT_DIR}/build/Sidekey-OrbMetal-dev.app" \
       "${PROJECT_DIR}/build/Sidekey-dev.app" \
       "${PROJECT_DIR}/build/Sidekey-Beta-dev.app"
stop_conflicting_sidekey_processes
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# --- Bundle the MLX Metal shader library (sealed RESOURCE + symlink) -------
# MLX (on-device LLM, ROO-257) loads its GPU kernels from a precompiled
# metallib at runtime; without it the first GPU op throws
#   "MLX error: Failed to load the default metallib. library not found".
# `swift build` cannot compile Metal shaders (upstream limitation), so the lib
# is precompiled into the committed Resources/mlx.metallib via
# scripts/build-metallib.sh. MLX's load_default_library() tries
# <binary_dir>/mlx.metallib first (see device.cpp). We mirror the production
# layout from build-dmg.sh: ship the lib as Contents/Resources/mlx.metallib and
# symlink Contents/MacOS/mlx.metallib -> ../Resources/mlx.metallib, so dev runs
# exercise the same colocated-via-symlink path the signed build ships. In the
# signed build that keeps the metallib a sealed resource instead of
# detached-signed nested code — the macOS 15 (Sequoia) first-launch Gatekeeper
# fix. Guarded so a tree that hasn't generated the lib yet still builds
# (inference just fails at runtime with the message above). The committed lib is
# version-locked to the resolved mlx-swift revision — bump MLX ⇒ re-run
# build-metallib.sh.
# WHY: docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md
MLX_METALLIB_SRC="${PROJECT_DIR}/Resources/mlx.metallib"
if [ -f "${MLX_METALLIB_SRC}" ]; then
    echo "▶ Bundling MLX metallib (Contents/Resources/mlx.metallib + MacOS symlink)..."
    cp "${MLX_METALLIB_SRC}" "${APP_BUNDLE}/Contents/Resources/mlx.metallib"
    ln -sf "../Resources/mlx.metallib" "${APP_BUNDLE}/Contents/MacOS/mlx.metallib"
else
    echo "⚠ Resources/mlx.metallib missing — on-device LLM inference will fail." >&2
    echo "  Generate it with: bash scripts/build-metallib.sh" >&2
fi

# Mirror build-dmg.sh: SwiftPM does NOT embed @executable_path/../Frameworks
# in the binary's rpath search list, so without this step dyld can't resolve
# the @rpath/Sparkle.framework/Versions/B/Sparkle install name at launch.
# launchd then refuses to spawn the app (RBSRequestErrorDomain Code=5 /
# POSIX 163 "Launchd job spawn failed"), and `open` reports nothing useful.
# `install_name_tool -add_rpath` fails (non-zero) if the rpath is already
# present, so guard against re-runs over a pre-patched binary copy.
if ! otool -l "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" \
        | grep -A2 LC_RPATH \
        | grep -q "@executable_path/../Frameworks"; then
    echo "▶ Adding @executable_path/../Frameworks to binary rpath..."
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
fi

# Pre-Stage-4 this script copied a static Resources/Info.plist. Stage 4
# replaced that file with Info.plist.template carrying placeholders that
# build-dmg.sh fills in per flavor. Mirror that substitution here so the
# dev bundle gets a valid plist without leaking the release-only secrets
# (no signed appcast key needed for a debug build that never ships).
if [ ! -f "${INFO_PLIST_TEMPLATE}" ]; then
    echo "✗ Info.plist template missing at ${INFO_PLIST_TEMPLATE}" >&2
    exit 1
fi

# Sparkle public key is checked into the repo (it is a public key — safe to
# inline into a dev build). Strip any stray whitespace exactly like
# build-dmg.sh does so the placeholder substitution stays well-formed.
if [ -f "${SPARKLE_PUBKEY_FILE}" ]; then
    SPARKLE_PUBLIC_ED_KEY="$(tr -d '\n\r ' < "${SPARKLE_PUBKEY_FILE}")"
else
    # Missing key is non-fatal for dev (Sparkle just won't validate updates
    # — and the dev bundle's high CFBundleVersion blocks discovery anyway).
    SPARKLE_PUBLIC_ED_KEY=""
fi

echo "▶ Rendering Info.plist from template (dev values)..."
sed -e "s|__BUNDLE_ID__|${BUNDLE_ID}|g" \
    -e "s|__BUNDLE_DISPLAY_NAME__|${BUNDLE_DISPLAY_NAME}|g" \
    -e "s|__BUNDLE_EXECUTABLE__|${EXECUTABLE_NAME}|g" \
    -e "s|__BUNDLE_ICON_FILE__|${BUNDLE_ICON_FILE}|g" \
    -e "s|__SHORT_VERSION__|${DEV_SHORT_VERSION}|g" \
    -e "s|__BUILD_VERSION__|${DEV_BUILD_VERSION}|g" \
    -e "s|__APPCAST_URL__|${DEV_APPCAST_URL}|g" \
    -e "s|__SPARKLE_PUBLIC_ED_KEY__|${SPARKLE_PUBLIC_ED_KEY}|g" \
    "${INFO_PLIST_TEMPLATE}" > "${APP_BUNDLE}/Contents/Info.plist"

if [ -f "${APP_ICON}" ]; then
    cp "${APP_ICON}" "${APP_BUNDLE}/Contents/Resources/${BUNDLE_ICON_FILE}.icns"
fi
if [ -f "${MENU_BAR_ICON}" ]; then
    cp "${MENU_BAR_ICON}" "${APP_BUNDLE}/Contents/Resources/MenuBarIconTemplate.pdf"
fi

# Useful Links chip icons — bundled provider logos (notion, linear, slack,
# github, gmail, gcalendar, jira, figma, asana, confluence, discord, trello)
# plus the globe fallback. Loaded by `UsefulLinkIconAsset` via
# `Bundle.main.url(forResource:withExtension:subdirectory:)` so we copy the
# whole directory verbatim — empty subdir copies cleanly even if a future
# refactor empties it out.
USEFUL_LINK_ICONS_DIR="${PROJECT_DIR}/Resources/UsefulLinkIcons"
if [ -d "${USEFUL_LINK_ICONS_DIR}" ]; then
    cp -R "${USEFUL_LINK_ICONS_DIR}" "${APP_BUNDLE}/Contents/Resources/UsefulLinkIcons"
fi

# Language picker flag PNGs. Loaded by the Dynamic Island language picker
# from Bundle.main/LanguageFlags so custom matte flags replace emoji glyphs
# in dev the same way they do in production builds.
LANGUAGE_FLAGS_DIR="${PROJECT_DIR}/Resources/LanguageFlags"
if [ -d "${LANGUAGE_FLAGS_DIR}" ]; then
    cp -R "${LANGUAGE_FLAGS_DIR}" "${APP_BUNDLE}/Contents/Resources/LanguageFlags"
fi

# Custom fonts (Instrument Serif Regular + Italic). Registered at launch
# via Info.plist's ATSApplicationFontsPath = "Fonts", consumed by the
# native SwiftUI onboarding for the editorial serif italic headlines.
FONTS_DIR="${PROJECT_DIR}/Resources/Fonts"
if [ -d "${FONTS_DIR}" ]; then
    cp -R "${FONTS_DIR}" "${APP_BUNDLE}/Contents/Resources/Fonts"
fi

# Onboarding voice samples. Loaded by `OnboardingAudioResources` from
# Bundle.main/OnboardingAudio so the real app matches the preview's audible
# Drop + Agent demos without relying on SwiftPM resource bundles in a signed
# .app wrapper.
ONBOARDING_AUDIO_DIR="${PROJECT_DIR}/Resources/OnboardingAudio"
if [ -d "${ONBOARDING_AUDIO_DIR}" ]; then
    cp -R "${ONBOARDING_AUDIO_DIR}" "${APP_BUNDLE}/Contents/Resources/OnboardingAudio"
fi

# Orb actions overlay icons (round 3) — the 3 PDFs that render inside
# the hover-only actions cluster: Agent (pink/violet small orb), Drop
# (white small orb), Clipboard (copy-icon-neon). Converted from SVGs
# via `rsvg-convert -f pdf`. Loaded by `OrbActionIcon.image()` from
# `Bundle.main.url(forResource:withExtension:)` so a flat copy into
# `Contents/Resources/` is all the runtime lookup needs.
for icon in orb-icon-agent orb-icon-drop copy-icon-neon; do
    if [ -f "${PROJECT_DIR}/Resources/${icon}.pdf" ]; then
        cp "${PROJECT_DIR}/Resources/${icon}.pdf" "${APP_BUNDLE}/Contents/Resources/${icon}.pdf"
    fi
done

# Dynamic Island hover-panel control orbs — bundled PDFs converted from
# Maxim's hand-drawn SVGs in `svg v2/` via `rsvg-convert -f pdf`. Loaded
# by `IslandControlIcon.image(named:)` from
# `Bundle.main.url(forResource:withExtension:)` (flat lookup), same as
# the orb-action PDFs above. New `island-*.pdf` assets join existing
# bundle artifacts — the older `orb-icon-*.pdf` / `copy-icon-neon.pdf`
# entries above stay in the loop because the floating-orb hover panel
# still depends on them.
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

# Meeting Notes BlockNote bundle (Stage 8a) — HTML + bundled JS + CSS
# loaded by the Meetings viewer's WKWebView via a file:// URL pointing at
# the .app's Contents/Resources/blocknote/. Mirror build-dmg.sh so dev and
# prod runs see the same bundle. The directory is committed; if missing
# (post-purge / shallow clone), regenerate via `bash scripts/build-blocknote.sh`.
BLOCKNOTE_BUNDLE_DIR="${PROJECT_DIR}/Resources/blocknote"
if [ -d "${BLOCKNOTE_BUNDLE_DIR}" ]; then
    cp -R "${BLOCKNOTE_BUNDLE_DIR}" "${APP_BUNDLE}/Contents/Resources/blocknote"
fi

# --- Bundle the MediaRemote adapter (prompt-free Now Playing source) --------
# Mirror build-dmg.sh: copy run.pl into Contents/Resources/MediaRemoteAdapter/
# and the framework into Contents/Frameworks/. Guarded so a dev tree without
# the vendored assets still runs (it just falls back to AppleScript). The
# framework is signed below before the app sign; dev entitlements already
# inject disable-library-validation so the dlopen'd framework loads.
MRA_PL_SRC="${PROJECT_DIR}/Resources/MediaRemoteAdapter/run.pl"
MRA_FW_SRC="${PROJECT_DIR}/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
if [ -f "${MRA_PL_SRC}" ] && [ -d "${MRA_FW_SRC}" ]; then
    echo "▶ Bundling MediaRemoteAdapter (run.pl + framework)..."
    mkdir -p "${APP_BUNDLE}/Contents/Resources/MediaRemoteAdapter"
    cp "${MRA_PL_SRC}" "${APP_BUNDLE}/Contents/Resources/MediaRemoteAdapter/run.pl"
    chmod 0644 "${APP_BUNDLE}/Contents/Resources/MediaRemoteAdapter/run.pl"
    mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
    rm -rf "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"
    ditto "${MRA_FW_SRC}" "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"
else
    echo "⚠ MediaRemoteAdapter assets missing — Now Playing will use AppleScript fallback." >&2
fi

# --- Embed Sparkle.framework -----------------------------------------------
#
# Stage 5 (#23) wired Sparkle into AppDelegate, so the linked binary now
# carries an @rpath dependency on Sparkle.framework. dev-run.sh has to embed
# it the same way build-dmg.sh does or launchd refuses to spawn the .app
# (silent dyld failure → POSIX 163 from `open`). We sign the helpers in the
# same deepest-first order documented at
# https://sparkle-project.org/documentation/sandboxing — `--deep` cannot
# apply distinct entitlement options per nested bundle.
SPARKLE_FRAMEWORK_SRC="$(find "${PROJECT_DIR}/.build" -name 'Sparkle.framework' -type d -path '*/Sparkle.xcframework/*' | head -1)"
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ]; then
    SPARKLE_FRAMEWORK_SRC="$(find "${PROJECT_DIR}/.build" -name 'Sparkle.framework' -type d | head -1)"
fi
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ]; then
    echo "✗ Sparkle.framework not found under .build/. Run 'swift build' first." >&2
    exit 1
fi

echo "▶ Embedding Sparkle.framework from ${SPARKLE_FRAMEWORK_SRC#"${PROJECT_DIR}/"}..."
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
rm -rf "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
ditto "${SPARKLE_FRAMEWORK_SRC}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

SPARKLE_BUNDLE="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B"

echo "▶ Signing Sparkle XPC services + helpers + framework (${SIGN_LABEL})..."
if [ -d "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc" ]; then
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime \
        "${SPARKLE_BUNDLE}/XPCServices/Installer.xpc"
fi
if [ -d "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc" ]; then
    # Downloader.xpc ships its own sandbox entitlements; preserve them so the
    # adhoc resign does not strip the sandboxing config Sparkle relies on.
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime \
        --preserve-metadata=entitlements \
        "${SPARKLE_BUNDLE}/XPCServices/Downloader.xpc"
fi
if [ -f "${SPARKLE_BUNDLE}/Autoupdate" ]; then
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime "${SPARKLE_BUNDLE}/Autoupdate"
fi
if [ -d "${SPARKLE_BUNDLE}/Updater.app" ]; then
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime "${SPARKLE_BUNDLE}/Updater.app"
fi
codesign --force --sign "${SIGN_IDENTITY}" --options runtime "${SPARKLE_BUNDLE}"

# Sign the MediaRemote adapter framework before the app sign (deepest-first,
# no --deep) so the dlopen'd framework satisfies the hardened runtime. Guarded
# on presence so a dev tree without the vendored framework still signs.
MRA_FW_DST="${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"
if [ -d "${MRA_FW_DST}" ]; then
    echo "▶ Signing MediaRemoteAdapter.framework (${SIGN_LABEL})..."
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime "${MRA_FW_DST}"
fi

# Sign the MLX metallib before the app sign (deepest-first, no --deep). A
# .metallib is a Mach-O-type artifact, so the single bundle codesign treats it
# as nested code and leaves it "not signed at all" (failing --verify --strict)
# unless we sign it explicitly first — same reason Sparkle/MediaRemoteAdapter
# are signed above.
MLX_METALLIB_DST="${APP_BUNDLE}/Contents/MacOS/mlx.metallib"
if [ -f "${MLX_METALLIB_DST}" ]; then
    echo "▶ Signing MLX metallib (${SIGN_LABEL})..."
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime "${MLX_METALLIB_DST}"
fi

# --- Dev entitlements (no team-id-prefixed keychain group) -----------------
#
# Resources/Sidekey.entitlements used to ship with keychain-access-groups
# containing the "<TEAM_ID>.com.rootwise.sidekey" team-id-prefixed group.
# AMFI treats that as a restricted entitlement: adhoc signatures cannot
# claim it, so adhoc signing refuses to spawn the app with
#   "AppleMobileFileIntegrityError Code=-424 The file is adhoc signed but
#    contains restricted entitlements"
# (visible in `log show --predicate 'eventMessage CONTAINS "Sidekey"'`).
#
# Strip that key for the dev bundle: `KeychainStore` (BYOK / LLM keys)
# does not use an access group, so nothing depends on it.
#
DEV_ENTITLEMENTS="${PROJECT_DIR}/build/${APP_BUNDLE_NAME%.app}.entitlements"
echo "▶ Generating dev entitlements (strip keychain group, allow unsigned libs)..."
# PlistBuddy edits in place — copy first so Resources/Sidekey.entitlements
# stays untouched. Two transformations:
#   1. Delete keychain-access-groups (Team-ID-prefixed → restricted entitlement
#      AMFI rejects on adhoc).
#   2. Add com.apple.security.cs.disable-library-validation. Without it,
#      hardened runtime + adhoc means dyld refuses to map any framework whose
#      Team ID differs from the host (it does even when both have no team ID
#      set, treating them as "non-platform" libraries) — Sparkle.framework
#      then fails to load with
#        "mapping process and mapped file (non-platform) have different
#         Team IDs"
#      visible in `DYLD_PRINT_LIBRARIES=1`. Library validation is a release
#      hardening; for dev it's safe (we control both the binary and Sparkle).
cp "${ENTITLEMENTS}" "${DEV_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" \
    "${DEV_ENTITLEMENTS}" 2>/dev/null || true
# `Add` fails non-zero if the key already exists from a prior run — fall
# back to `Set` which idempotently overwrites.
/usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.cs.disable-library-validation bool true" \
    "${DEV_ENTITLEMENTS}" 2>/dev/null \
    || /usr/libexec/PlistBuddy \
        -c "Set :com.apple.security.cs.disable-library-validation true" \
        "${DEV_ENTITLEMENTS}"

echo "▶ Signing app bundle with dev entitlements (${SIGN_LABEL}, bundle id: ${BUNDLE_ID})..."
# No --deep — Sparkle helpers and framework are already signed individually,
# matching build-dmg.sh's signing strategy.
codesign \
    --force \
    --sign "${SIGN_IDENTITY}" \
    --entitlements "${DEV_ENTITLEMENTS}" \
    --options runtime \
    "${APP_BUNDLE}"

echo "▶ Verifying signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
    echo "▶ Refreshing LaunchServices registration..."
    "${LSREGISTER}" -f "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi
touch "${APP_BUNDLE}"
qlmanage -r cache >/dev/null 2>&1 || true
killall iconservicesagent >/dev/null 2>&1 || true

echo ""
echo "✓ Built: ${APP_BUNDLE}"
echo ""

if [ "${RUN_AFTER_BUILD}" -eq 1 ]; then
    # The app needs no env vars at launch: STT / LLM run on-device or with
    # the user's own provider keys stored in the macOS Keychain, so `open`
    # is enough — it does not pass the calling shell's env to the launched
    # app, but the app does not read any.
    #
    # If a future change reintroduces an env requirement, do NOT add it to a
    # plain file. Bridge it through launchd briefly:
    #   launchctl setenv KEY "$(doppler secrets get KEY ... --plain)"
    #   open "${APP_BUNDLE}"
    #   launchctl unsetenv KEY
    # so the value lives in the launchd context only long enough for `open`
    # to spawn the child, then is removed from the global namespace.
    stop_conflicting_sidekey_processes
    sleep 0.5

    echo "▶ Launching ${BUNDLE_DISPLAY_NAME}..."
    if [ "${#LAUNCH_ARGS[@]}" -gt 0 ]; then
        open "${APP_BUNDLE}" --args "${LAUNCH_ARGS[@]}"
    else
        open "${APP_BUNDLE}"
    fi
else
    echo "To launch:"
    echo "  open ${APP_BUNDLE}"
    echo ""
    echo "Or rerun with --run to build and launch in one step."
fi
