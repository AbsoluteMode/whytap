#!/usr/bin/env python3
"""Write the README "Free API keys" section from the app's API hints.

The offers live in one place, `APIHintsView.hints` in
Sources/Sidekey/Settings/APIAndModels/APIHintsView.swift, which Settings ->
API & Models -> API hints shows. This script turns the offers that need no
card (`access: .noCard`) into small linked cards (docs/assets/readme/
free-api-*.svg, dark and light, logos from Resources/UsefulLinkIcons) at the
end of README.md, under one line with the newest check date. Only the
provider, allowance, period and purpose: details stay in the app.

Usage:
    python3 scripts/readme-free-apis.py          # rewrite README.md
    python3 scripts/readme-free-apis.py --check  # exit 1 if README.md is stale

The monthly review updates the Swift offers first (amounts, details, `checked`)
and then runs this script, so the app and the README never disagree.
"""
# WHY: .project-docs/decisions/2026-11-21-free-api-report.md
import datetime, html, pathlib, re, sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SWIFT = REPO / "Sources/Sidekey/Settings/APIAndModels/APIHintsView.swift"
README = REPO / "README.md"
HEADING = "## Free API keys"
CATEGORY = {"speech": "Speech to text", "models": "Language models", "search": "Web search"}
DEFAULT_CHECKED = "2026-10-19"  # Hint.checked default in the Swift struct


def offers():
    src = SWIFT.read_text()
    block = src[src.index("static let hints: [Hint] = ["):]
    block = block[: block.index("\n    ]\n")]
    out = []
    for chunk in block.split("Hint(")[1:]:
        fields = {}
        for key, value in re.findall(r'(\w+):\s*(URL\(string: "[^"]*"\)!|"(?:[^"\\]|\\.)*"|\.\w+)', chunk):
            if value.startswith("URL("):
                value = re.search(r'"([^"]*)"', value).group(1)
            elif value.startswith('"'):
                value = value[1:-1].replace('\\"', '"')
            else:
                value = value[1:]
            fields[key] = value
        missing = {"category", "provider", "allowance", "cadence", "access", "detail", "url"} - fields.keys()
        if missing:
            sys.exit(f"Could not read {sorted(missing)} from an offer in {SWIFT}")
        fields.setdefault("checked", DEFAULT_CHECKED)
        out.append(fields)
    return out


def display(iso):
    d = datetime.date.fromisoformat(iso)
    return f"{d:%B} {d.day}, {d.year}"


THEMES = {
    "dark": dict(bg="#151b23", border="#2d333b", ink="#f0f6fc", sub="#9198a1", accent="#b8adff"),
    "light": dict(bg="#f6f8fa", border="#d1d9e0", ink="#1f2328", sub="#59636e", accent="#5b4bd6"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
W, H = 196, 124
ICONS = REPO / "Resources/UsefulLinkIcons"
OUT = REPO / "docs/assets/readme"


def logo(asset, color, x, y, size):
    svg = (ICONS / f"{asset}.svg").read_text()
    svg = re.sub(r"<title>.*?</title>", "", svg, flags=re.S)
    svg = re.sub(r"#(?:111111|000000)", color, svg)
    if 'fill="' not in svg.split(">", 1)[0]:
        svg = svg.replace("<svg ", f'<svg fill="{color}" ', 1)
    return svg.replace("<svg ", f'<svg x="{x}" y="{y}" width="{size}" height="{size}" ', 1)


def short(cadence):
    return cadence[5:] if cadence.startswith("free ") else cadence


def card(o, theme):
    c = THEMES[theme]
    e = lambda t: html.escape(t, quote=False)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="14" fill="{c['bg']}" stroke="{c['border']}"/>
  {logo(o["assetName"], c["ink"], 16, 16, 18)}
  <text x="42" y="30" font-family="{FONT}" font-size="14" font-weight="600" fill="{c['ink']}">{e(o['provider'])}</text>
  <text x="16" y="70" font-family="{FONT}" font-size="28" font-weight="700" fill="{c['ink']}">{e(o['allowance'])}</text>
  <text x="16" y="89" font-family="{FONT}" font-size="12" fill="{c['sub']}">{e(short(o['cadence']))}</text>
  <text x="16" y="110" font-family="{FONT}" font-size="11.5" font-weight="600" fill="{c['accent']}">{e(CATEGORY[o['category']])}</text>
</svg>
'''


def section():
    rows = [o for o in offers() if o["access"] == "noCard"]
    order = list(CATEGORY)
    rows.sort(key=lambda o: order.index(o["category"]))  # stable: Swift order within a category
    newest = max(o["checked"] for o in rows)
    for old in OUT.glob("free-api-*.svg"):
        old.unlink()
    cards = []
    for o in rows:
        slug = re.sub(r"[^a-z0-9]+", "-", o["provider"].lower()).strip("-")
        for t in THEMES:
            (OUT / f"free-api-{slug}-{t}.svg").write_text(card(o, t))
        src = lambda t: f"docs/assets/readme/free-api-{slug}-{t}.svg"
        alt = html.escape(f"{o['provider']}: {o['allowance']} {o['cadence']} ({CATEGORY[o['category']]})")
        cards.append(
            f'<a href="{o["url"]}"><picture>'
            f'<source media="(prefers-color-scheme: dark)" srcset="{src("dark")}">'
            f'<source media="(prefers-color-scheme: light)" srcset="{src("light")}">'
            f'<img alt="{alt}" src="{src("dark")}" width="{W}"></picture></a>'
        )
    return "\n".join([
        HEADING,
        "",
        f"<sub>No card needed · Reviewed monthly · Last checked {display(newest)}</sub>",
        "",
        "<p align=\"center\">",
        "\n".join(cards),
        "</p>",
    ]) + "\n"


def updated(readme):
    new = section()
    if HEADING in readme:
        start = readme.index(HEADING)
        nxt = re.search(r"^## ", readme[start + len(HEADING):], re.M)
        end = start + len(HEADING) + nxt.start() if nxt else len(readme)
        tail = "\n" + readme[end:] if nxt else ""
        return readme[:start] + new + tail
    return readme.rstrip("\n") + "\n\n" + new


if __name__ == "__main__":
    current = README.read_text()
    result = updated(current)
    if "--check" in sys.argv:
        if result != current:
            sys.exit("README.md Free API keys section is out of date: run scripts/readme-free-apis.py")
        print("README.md Free API keys section is current")
    else:
        README.write_text(result)
        print("ok")
