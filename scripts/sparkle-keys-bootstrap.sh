#!/usr/bin/env bash
#
# sparkle-keys-bootstrap.sh — One-shot EdDSA keypair bootstrap for Sparkle.
#
# Run this once, ever, when first wiring Sparkle into the project.
# After the private key is in your secret store and Resources/sparkle-public-ed-key.txt
# is committed, this script never needs to be run again.
#
# Re-running it would generate a new keypair — installs in the wild that have
# the old SUPublicEDKey embedded would reject any DMG signed with the new key
# (signature mismatch), bricking auto-update for those users. Don't.
#
# What this does:
#   1. Locates Sparkle's `generate_keys` binary inside the SwiftPM artifact
#      bundle (requires `swift build` to have run at least once).
#   2. Calls `generate_keys -p` which prints the public key to stdout AND
#      stores the private key in the macOS Keychain under
#      "Private key for signing Sparkle updates" (account: "ed25519").
#   3. Saves the public key to Resources/sparkle-public-ed-key.txt.
#   4. Prints follow-up instructions for exporting the private key and
#      storing it in your secret manager (the official builds use Doppler,
#      a fork can simply export SPARKLE_ED_PRIVATE_KEY in the shell).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PUBKEY_FILE="${PROJECT_DIR}/Resources/sparkle-public-ed-key.txt"

GENERATE_KEYS_BIN="$(find "${PROJECT_DIR}/.build" -name 'generate_keys' -type f -perm -u+x | head -1)"
if [[ -z "${GENERATE_KEYS_BIN}" ]]; then
    echo "ERROR: generate_keys not found in .build/." >&2
    echo "Run 'swift build' from the repo root, then re-run this script." >&2
    exit 1
fi

echo "▶ Using ${GENERATE_KEYS_BIN}"

# Refuse to clobber an existing public key — operator must delete it explicitly
# (and only after thinking through the keychain-rotation consequences described
# in the header comment).
if [[ -s "${PUBKEY_FILE}" ]]; then
    echo "ERROR: ${PUBKEY_FILE} already exists and is non-empty." >&2
    echo "Refusing to overwrite — rotating EdDSA keys breaks auto-update for" >&2
    echo "every existing install. If you really intend to rotate:" >&2
    echo "  1. Read the comment at the top of this script." >&2
    echo "  2. Manually delete ${PUBKEY_FILE} and the matching keychain entry," >&2
    echo "     then re-run this script." >&2
    exit 1
fi

# `generate_keys -p` reads the existing keypair from the macOS Keychain and
# prints the public part. If no keypair exists yet, `-p` exits non-zero with
# empty output; the bare `generate_keys` invocation (no flags) is what
# generates a fresh keypair and stores it in the Keychain.
#
# Try -p first, fall back to bare generation only on the very first run.
set +e
PUB_KEY="$("${GENERATE_KEYS_BIN}" -p 2>/dev/null)"
PUB_KEY_EXIT=$?
set -e

if [[ ${PUB_KEY_EXIT} -ne 0 ]] || [[ -z "${PUB_KEY}" ]]; then
    echo "▶ No EdDSA keypair in Keychain yet — generating a new one"
    # Bare invocation generates and stores in Keychain; output is human-readable
    # instructions, not the key itself. We re-fetch via -p on the next line.
    "${GENERATE_KEYS_BIN}" >/dev/null
    PUB_KEY="$("${GENERATE_KEYS_BIN}" -p)"
    if [[ -z "${PUB_KEY}" ]]; then
        echo "ERROR: failed to generate or read EdDSA keypair." >&2
        echo "Inspect manually:" >&2
        echo "  ${GENERATE_KEYS_BIN}" >&2
        echo "  ${GENERATE_KEYS_BIN} -p" >&2
        exit 1
    fi
fi

# Strip whitespace defensively — Info.plist substitution expects a single
# clean base64 token and the format check rejects anything else.
printf '%s' "${PUB_KEY}" | tr -d '\n\r ' > "${PUBKEY_FILE}"

echo "✓ Saved public key to Resources/sparkle-public-ed-key.txt"
echo "  $(cat "${PUBKEY_FILE}")"
echo ""
echo "Next steps (manual):"
echo ""
echo "  1. Commit Resources/sparkle-public-ed-key.txt — public, not secret."
echo ""
echo "  2. Export the private key from the macOS Keychain and store it where your release shell can read it"
echo "     for dev / stg / prd configs of the \`sidekey\` project:"
echo ""
echo "       ${GENERATE_KEYS_BIN} -x ~/sparkle_priv.txt"
echo "       export SPARKLE_ED_PRIVATE_KEY=\"\$(cat ~/sparkle_priv.txt)\"   # or: doppler secrets set SPARKLE_ED_PRIVATE_KEY=... "
echo "       rm ~/sparkle_priv.txt"
echo ""
echo "  3. Verify by round-tripping through base64:"
echo "       printf %s \"\$SPARKLE_ED_PRIVATE_KEY\" | base64 -d | wc -c"
echo "     Expected: 32 (Ed25519 seed size)."
