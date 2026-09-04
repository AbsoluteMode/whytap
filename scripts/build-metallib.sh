#!/usr/bin/env bash
#
# build-metallib.sh — Compile MLX's Metal shader library (default.metallib) and
# stage it as the committed artifact Resources/mlx.metallib (ROO-257).
#
# Why this exists:
#   MLX Swift ships its GPU kernels as Metal source (49 *.metal files under the
#   `mlx-swift` checkout). At runtime MLX loads a precompiled `default.metallib`;
#   without it, the first GPU op throws
#     "MLX error: Failed to load the default metallib. library not found".
#   The SwiftPM NATIVE build system (`swift build`, used by dev-run.sh and
#   build-dmg.sh) CANNOT compile Metal shaders — upstream documents this
#   explicitly (mlx-swift README: "SwiftPM (command line) cannot build the
#   Metal shaders so the ultimate build has to be done via Xcode"). `xcodebuild`
#   CAN, via the `Cmlx` scheme in the checkout's xcode/MLX.xcodeproj, which runs
#   the metal kernel compile + `metallib` link the CMakeLists describes.
#
#   So we compile the metallib once via xcodebuild against the resolved
#   mlx-swift checkout and commit the result as Resources/mlx.metallib (treated
#   as a build artifact, like Resources/AppIcon.icns or Resources/blocknote/).
#   Both dev-run.sh and build-dmg.sh then copy it next to the app executable.
#
# Runtime lookup (verified against mlx/backend/metal/device.cpp):
#   MLX's load_default_library() searches, in order:
#     1. <binary_dir>/mlx.metallib              (load_colocated_library "mlx")
#     2. <binary_dir>/Resources/mlx.metallib
#     3. <mainBundle>/mlx-swift_Cmlx.bundle/.../default.metallib (SwiftPM bundle)
#     4. <binary_dir>/Resources/default.metallib
#   We target step 1, but the lib ships as a sealed RESOURCE at
#   Contents/Resources/mlx.metallib with a symlink Contents/MacOS/mlx.metallib
#   -> ../Resources/mlx.metallib (see build-dmg.sh / dev-run.sh). A bare
#   .metallib signed directly in Contents/MacOS/ becomes detached-signed nested
#   code that breaks macOS 15 (Sequoia) first-launch Gatekeeper; the
#   sealed-resource + symlink layout avoids that while keeping colocated lookup.
#   There is NO METAL_PATH env override — the override is a C++ API only.
#   WHY: docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md
#
# Output (committed): Resources/mlx.metallib + Resources/mlx.metallib.revision
#   metallib: ~3.7 MB, air64-apple-macosx — arm64 only. MLX is Apple-Silicon-only
#   and the Local LLM feature is Apple-Silicon-gated, so an arm64-only metallib is
#   correct: Intel Macs never run MLX inference and never load this lib.
#   .revision: a sidecar holding the 40-char mlx-swift git SHA the kernels were
#   compiled from (read from Package.resolved). The release pre-flight compares
#   it against the current pin to detect drift.
#
# VERSION LOCK (ENFORCED):
#   The committed Resources/mlx.metallib is version-locked to the mlx-swift
#   revision resolved in Package.resolved. The kernels are compiled from THAT
#   checkout's *.metal sources, so bumping mlx-swift (or mlx-swift-lm pulling a
#   new mlx-swift) REQUIRES re-running this script to regenerate the metallib —
#   a stale lib against new MLX runtime expectations can crash or mis-execute
#   GPU ops. Treat a Package.resolved MLX bump and this artifact as a single
#   atomic change.
#   This is no longer just a convention: `--check` (wired into build-dmg.sh's
#   pre-flight, and thus user-release.sh) HARD-FAILS the release if the recorded
#   .revision sidecar does not equal the current Package.resolved mlx-swift pin.
#   A forgotten regeneration after an MLX bump now blocks the build loudly
#   instead of shipping a DMG whose GPU kernels mismatch the runtime.
#
# Prerequisites:
#   - `swift build` must have run at least once so the mlx-swift dependency is
#     resolved into .build/checkouts/mlx-swift (this script reads its xcodeproj).
#   - An Xcode toolchain with the Metal compiler (`xcrun -f metal` / `metallib`).
#
# Usage:
#   ./scripts/build-metallib.sh          # build + stage lib + .revision sidecar
#   ./scripts/build-metallib.sh --check  # verify lib exists + is a valid MetalLib
#                                        # AND its .revision matches Package.resolved

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MLX_CHECKOUT="${PROJECT_DIR}/.build/checkouts/mlx-swift"
XCODEPROJ="${MLX_CHECKOUT}/xcode/MLX.xcodeproj"
DEST="${PROJECT_DIR}/Resources/mlx.metallib"
# Sidecar recording the mlx-swift revision the committed metallib was compiled
# from. Bound to Resources/mlx.metallib; both are regenerated atomically here.
REVISION_SIDECAR="${DEST}.revision"
PACKAGE_RESOLVED="${PROJECT_DIR}/Package.resolved"

# Read the pin revision for a given package identity out of Package.resolved.
# Echoes the 40-char git SHA, or nothing (with a non-zero exit) if absent. Uses
# /usr/bin/python3 (always present on macOS) to parse the JSON rather than a
# fragile grep — Package.resolved is the source of truth for the resolved
# dependency graph.
resolved_revision() {
    local identity="$1"
    /usr/bin/python3 - "${PACKAGE_RESOLVED}" "${identity}" <<'PY'
import json
import sys

path, identity = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        data = json.load(handle)
except OSError:
    sys.exit(1)

for pin in data.get("pins", []):
    if pin.get("identity") == identity:
        revision = (pin.get("state") or {}).get("revision", "")
        if revision:
            print(revision)
            sys.exit(0)
        sys.exit(1)
sys.exit(1)
PY
}

check_artifact() {
    if [ ! -f "${DEST}" ]; then
        echo "ERROR: ${DEST#"${PROJECT_DIR}/"} missing. Run: bash scripts/build-metallib.sh" >&2
        return 1
    fi
    # `file` reports "MetalLib executable" for a valid metallib. A truncated or
    # wrong-type file (e.g. an accidentally-committed text stub) fails here.
    if ! file "${DEST}" | grep -q 'MetalLib'; then
        echo "ERROR: ${DEST#"${PROJECT_DIR}/"} is not a valid MetalLib (got: $(file -b "${DEST}"))." >&2
        return 1
    fi

    # Version lock: the committed metallib's GPU kernels are compiled from a
    # SPECIFIC mlx-swift checkout. If Package.resolved later pins a different
    # mlx-swift revision but the metallib was not regenerated, the shipped
    # kernels mismatch the MLX runtime and can crash on the first local-LLM op.
    # Hard-fail on drift here so the release path (build-dmg.sh wires `--check`)
    # blocks rather than building/signing/notarizing a broken DMG.
    local resolved
    if ! resolved="$(resolved_revision mlx-swift)"; then
        echo "ERROR: could not read mlx-swift revision from Package.resolved." >&2
        echo "  Run 'swift build' to resolve dependencies, then re-run build-metallib.sh." >&2
        return 1
    fi
    if [ ! -f "${REVISION_SIDECAR}" ]; then
        echo "ERROR: ${REVISION_SIDECAR#"${PROJECT_DIR}/"} missing — the metallib is not version-locked." >&2
        echo "  Regenerate the lib + sidecar: bash scripts/build-metallib.sh" >&2
        return 1
    fi
    local recorded
    recorded="$(tr -d '\n\r ' < "${REVISION_SIDECAR}")"
    if [ "${recorded}" != "${resolved}" ]; then
        echo "ERROR: metallib is STALE — mlx-swift revision drifted." >&2
        echo "  Resources/mlx.metallib was built from mlx-swift @ ${recorded}" >&2
        echo "  but Package.resolved now pins mlx-swift @ ${resolved}." >&2
        echo "  Regenerate the lib (Metal kernels must match the runtime):" >&2
        echo "    bash scripts/build-metallib.sh" >&2
        echo "  Treat an MLX bump + this artifact as a single atomic change." >&2
        return 1
    fi

    echo "  ok: $(du -h "${DEST}" | cut -f1) MetalLib at Resources/mlx.metallib (mlx-swift @ ${resolved})"
    return 0
}

if [ "${1:-}" = "--check" ]; then
    check_artifact
    exit $?
fi

if [ ! -d "${XCODEPROJ}" ]; then
    echo "ERROR: mlx-swift xcodeproj not found at ${XCODEPROJ#"${PROJECT_DIR}/"}." >&2
    echo "Run 'swift build' first so the mlx-swift dependency is resolved into .build/checkouts/." >&2
    exit 1
fi

if ! xcrun -f metallib >/dev/null 2>&1; then
    echo "ERROR: Metal toolchain not found (xcrun -f metallib failed)." >&2
    echo "Install a full Xcode (the Metal compiler is required to build the shaders)." >&2
    exit 1
fi

# Build the Cmlx scheme — it compiles the 49 metal kernels and links them into
# default.metallib inside the Cmlx.framework. A dedicated derivedData dir keeps
# this build isolated from the SwiftPM .build tree.
DERIVED_DATA="$(mktemp -d -t sidekey-metallib)"
cleanup() { rm -rf "${DERIVED_DATA}"; }
trap cleanup EXIT

echo "▶ Compiling MLX metal shaders via xcodebuild (Cmlx scheme)... this is slow."
xcodebuild build \
    -project "${XCODEPROJ}" \
    -scheme Cmlx \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    >"${DERIVED_DATA}/xcodebuild.log" 2>&1 || {
        echo "ERROR: xcodebuild failed. Tail of log:" >&2
        tail -40 "${DERIVED_DATA}/xcodebuild.log" >&2
        exit 1
    }

SRC="$(find "${DERIVED_DATA}" -name 'default.metallib' -type f | head -1)"
if [ -z "${SRC}" ] || [ ! -f "${SRC}" ]; then
    echo "ERROR: xcodebuild succeeded but no default.metallib was produced." >&2
    echo "  searched: ${DERIVED_DATA}" >&2
    exit 1
fi

mkdir -p "${PROJECT_DIR}/Resources"
cp "${SRC}" "${DEST}"

# Record the mlx-swift revision the kernels were compiled from, alongside the
# lib. The release pre-flight (`--check`, wired into build-dmg.sh) fails if this
# drifts from the current Package.resolved mlx-swift pin — so a future MLX bump
# that forgets to regenerate the metallib cannot ship a mismatched DMG.
if ! MLX_REVISION="$(resolved_revision mlx-swift)"; then
    echo "ERROR: built the metallib but could not read mlx-swift revision from" >&2
    echo "  Package.resolved to write the version-lock sidecar. Run 'swift build'" >&2
    echo "  first so the dependency graph is resolved, then re-run." >&2
    exit 1
fi
printf '%s\n' "${MLX_REVISION}" > "${REVISION_SIDECAR}"

echo "▶ Staged Resources/mlx.metallib (compiled from mlx-swift @ ${MLX_REVISION})."
echo "▶ Wrote version-lock sidecar Resources/mlx.metallib.revision."
check_artifact
