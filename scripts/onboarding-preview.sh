#!/bin/bash
# Builds and opens the whole Whytap onboarding as a standalone window, outside
# Whytap, for review after each change. Isolated: its own defaults suite
# (emptied on start and quit), keys in memory, offline key checks (a key
# containing "bad" is refused), pretend permissions, Simulate Drop. It never
# touches /Applications/Whytap.app, com.rootwise.sidekey, the Keychain or the
# network, and starts no hotkeys or event taps.
# WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
#
# Usage: scripts/onboarding-preview.sh            (build, then open from step 1)
#        scripts/onboarding-preview.sh --build-only
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product OnboardingPreview >/tmp/whytap-onboarding-preview-build.log 2>&1 || {
    tail -c 3000 /tmp/whytap-onboarding-preview-build.log >&2
    exit 1
}
BIN="$(swift build --show-bin-path)/OnboardingPreview"
echo "Built $BIN"
[[ "${1:-}" == "--build-only" ]] && exit 0

# One preview at a time: a rebuild replaces the window that is open.
pkill -x OnboardingPreview 2>/dev/null || true
nohup "$BIN" >/tmp/whytap-onboarding-preview.log 2>&1 &
echo "Opened the onboarding preview (pid $!). Quit with ⌘Q or finish the last step."
