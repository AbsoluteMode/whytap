#!/usr/bin/env bash
#
# build-blocknote.sh — Build the BlockNote bundle embedded inside Sidekey's
# Meeting Notes viewer (Stage 8a).
#
# Inputs:  scripts/blocknote-src/{package.json, vite.config.ts, src/main.tsx, ...}
# Output:  Resources/blocknote/{index.html, assets/...}
#
# Run this script before `scripts/build-dmg.sh`; the DMG script has a
# pre-flight check that aborts if the bundle is missing. The output is
# committed to the repo (treated as a build artifact, like AppIcon.icns) so
# CI / collaborators don't need Node installed unless they're regenerating
# the bundle.
#
# Reproducibility notes:
#   - All npm versions are pinned exact (no `^` ranges) in package.json.
#   - First run uses `npm install` to create `package-lock.json`; subsequent
#     runs use `npm ci` for fully reproducible installs from the lock.
#   - Vite emits a single bundle (no code-splitting, no dynamic imports)
#     so the file:// loader + strict CSP do not need any extra entries.
#
# Size budget: 2 MB hard cap (`du -sk`). Most of the weight comes from
# Mantine + BlockNote core; if we exceed the cap, drop @blocknote/mantine
# and use the headless @blocknote/react variant.
set -euo pipefail

cd "$(dirname "$0")/blocknote-src"

if [ ! -d node_modules ]; then
  if [ -f package-lock.json ]; then
    echo "▶ Installing npm deps (npm ci, reproducible from lock)..."
    npm ci
  else
    echo "▶ Installing npm deps (npm install, creating lock)..."
    npm install
  fi
fi

echo "▶ Building BlockNote bundle..."
npm run build

cd ../..

# --- Validate output ---------------------------------------------------------

if [ ! -f Resources/blocknote/index.html ]; then
  echo "ERROR: Resources/blocknote/index.html missing after build" >&2
  exit 1
fi

# Two file:// hostile artifacts come out of the Vite build and need
# stripping here so the bundle actually renders inside WKWebView:
#
# 1. `crossorigin` attribute on <script type="module"> and <link rel=
#    "stylesheet">. Vite adds it for anonymous CORS preloads on a real
#    web server, but under `file://` there are no CORS headers — the
#    browser silently fails the check, the module never loads, React
#    never mounts, white pane.
#
# 2. The CSP meta tag (`<meta http-equiv="Content-Security-Policy" ...>`)
#    that scaffolds out as `default-src 'self'; script-src 'self'; ...`.
#    On `file://` origins WebKit treats every URL as the null origin, so
#    `'self'` matches nothing and CSP blocks the very script the page
#    needs. The BlockNote bundle is 100% trusted, locally-shipped code
#    (no user-provided HTML, no third-party scripts at runtime), so we
#    drop CSP entirely rather than try to express a self-compatible
#    policy under file://. If we ever move the bundle behind a custom
#    URL scheme handler, re-add CSP with `default-src sidekey-app:`.
#
# An earlier attempt to relax file-from-file via private WKPreferences
# keys (`allowUniversalAccessFromFileURLs`) crashed modern WKWebView at
# first menu click because the key is not KVC-compliant.
echo "▶ Patching index.html for file:// (strip crossorigin + drop CSP meta + downgrade type=module to classic script)..."
python3 - "Resources/blocknote/index.html" <<'PY'
import sys, re
path = sys.argv[1]
html = open(path, encoding='utf-8').read()
# Drop CSP meta — `'self'` matches nothing under file:// (null origin).
html = re.sub(
    r'\s*<meta\s+http-equiv="Content-Security-Policy"[^>]*content="[^"]*"\s*/?>\s*',
    '\n    ',
    html,
    flags=re.DOTALL | re.IGNORECASE,
)
# Strip crossorigin attribute (Vite adds it for anonymous CORS preloads
# on real servers; under file:// there's no CORS, attribute aborts fetch).
html = re.sub(r' crossorigin', '', html)
# Downgrade `<script type="module" src="...">` to classic `<script defer src="...">`.
# WebKit refuses to load ES modules from `file://` origins (file URLs are
# not a "trustworthy origin" for the module loader — the fetch never
# even appears in Web Inspector → Network, and no error is logged). The
# Vite build is configured for `output.format: "iife"` so the emitted JS
# is a self-contained classic script — `type="module"` was leftover from
# Vite's HTML plugin and is now harmful.
#
# `defer` is non-optional: classic scripts execute synchronously at parse
# time, BEFORE `<body>` is parsed. main.tsx calls
# `document.getElementById("root")` immediately and throws if the element
# is missing — without `defer` we'd hit that throw on every load. `defer`
# postpones execution until after the whole document is parsed (same
# ordering ES modules give us for free).
html = re.sub(r' type="module" src=', ' defer src=', html)
# Belt-and-suspenders: if the regex above didn't match (e.g. attr order
# differs in a future Vite version), at least drop the type=module.
html = re.sub(r' type="module"', ' defer', html)
# Inject a baseline dark-background stylesheet right before </head>.
# Without this, the area outside the BlockNote editor canvas (page
# margins, scroll padding, the brief moment before React mounts) shows
# the WKWebView default WHITE background, which creates jarring white
# "borders" around the dark editor. The colour matches Mantine's dark
# scheme (`#1a1a1a` — close enough to BlockNote's own dark canvas that
# the seam is invisible). `#root` fills the viewport so the editor
# canvas extends to the window edges.
sidekey_style = (
    '<style>'
    'html, body { margin: 0; padding: 0; height: 100vh; '
    'background: #1a1a1a; color-scheme: dark; }'
    '#root { height: 100vh; }'
    '</style>'
)
html = html.replace('</head>', sidekey_style + '\n  </head>', 1)
open(path, 'w', encoding='utf-8').write(html)
PY
if grep -q crossorigin Resources/blocknote/index.html; then
  echo "ERROR: 'crossorigin' still present in Resources/blocknote/index.html" >&2
  exit 1
fi
if grep -q "Content-Security-Policy" Resources/blocknote/index.html; then
  echo "ERROR: CSP meta tag still present in Resources/blocknote/index.html" >&2
  exit 1
fi
if grep -q 'type="module"' Resources/blocknote/index.html; then
  echo "ERROR: 'type=\"module\"' still present in Resources/blocknote/index.html" >&2
  exit 1
fi

ASSETS_COUNT=$(find Resources/blocknote/assets -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "${ASSETS_COUNT}" = "0" ]; then
  echo "ERROR: Resources/blocknote/assets/ is empty after build" >&2
  exit 1
fi

SIZE_KB=$(du -sk Resources/blocknote/ | cut -f1)
SIZE_CAP_KB=2048
if [ "${SIZE_KB}" -gt "${SIZE_CAP_KB}" ]; then
  echo "ERROR: BlockNote bundle size ${SIZE_KB}KB > ${SIZE_CAP_KB}KB cap. Fail." >&2
  echo "Consider dropping @blocknote/mantine and using @blocknote/react alone." >&2
  exit 1
fi

echo "✓ BlockNote bundle ready: ${SIZE_KB}KB at Resources/blocknote/ (cap ${SIZE_CAP_KB}KB)"
