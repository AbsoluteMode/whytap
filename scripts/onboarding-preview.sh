#!/usr/bin/env bash
# onboarding-preview.sh
#
# Builds and launches the standalone OnboardingPreview executable —
# a tiny SwiftUI app whose only job is to render the onboarding
# welcome screen for visual iteration. It does NOT touch the main
# Sidekey bundle (no menu bar, no hotkey, no backend, no Sparkle).
#
# Usage:
#   ./scripts/onboarding-preview.sh             # build + launch
#   ./scripts/onboarding-preview.sh --no-build  # launch existing build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARY="${PROJECT_DIR}/.build/debug/OnboardingPreview"

SKIP_BUILD=0
for arg in "$@"; do
    if [ "${arg}" = "--no-build" ]; then
        SKIP_BUILD=1
    fi
done

if [ "${SKIP_BUILD}" = "0" ]; then
    echo "▶ Building OnboardingPreview..."
    cd "${PROJECT_DIR}"
    swift build --product OnboardingPreview
fi

if [ ! -x "${BINARY}" ]; then
    echo "✗ OnboardingPreview binary missing at ${BINARY}" >&2
    echo "  Run without --no-build to build first." >&2
    exit 1
fi

# Kill any prior preview instance so the new one wins the foreground.
pkill -f "${BINARY}" 2>/dev/null || true
sleep 0.2

echo "▶ Launching onboarding preview window..."
"${BINARY}" &

echo "✓ Preview running (PID $!). Close the window to quit."
