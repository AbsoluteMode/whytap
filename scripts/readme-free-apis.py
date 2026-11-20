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

# Typical yearly cost of the paid Mac apps Whytap stands in for: dictation ~$12,
# meeting notes ~$15, AI launcher ~$16 and secrets vault ~$10 a month (the
# README's earlier per-tool comparison), about $636 a year. An estimate, shown
# as approximate; Maxim chose the figure on 2026-11-21.
PAID_YEARLY = "$600"  # shown struck through; the caption and alt say it is approximate
BANNER = {"wide": (640, 116), "phone": (300, 96)}


def banner(theme, layout):
    c = THEMES[theme]
    w, h = BANNER[layout]
    big, cap = (44, 13) if layout == "wide" else (30, 10.5)
    left, right, mid = w * 0.27, w * 0.73, w / 2
    y_num, y_cap = h * 0.52, h * 0.52 + cap * 1.9
    strike = c["sub"]
    green = "#3fb950" if theme == "dark" else "#1a7f37"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
  <rect x="0.5" y="0.5" width="{w-1}" height="{h-1}" rx="16" fill="{c['bg']}" stroke="{c['border']}"/>
  <text x="{left}" y="{y_num}" text-anchor="middle" font-family="{FONT}" font-size="{big}" font-weight="700" fill="{c['sub']}">{html.escape(PAID_YEARLY)}</text>
  <line x1="{left - big * 1.22}" y1="{y_num - big * 0.33}" x2="{left + big * 1.22}" y2="{y_num - big * 0.33}" stroke="{strike}" stroke-width="{2.5 if layout == 'wide' else 2}" stroke-linecap="round"/>
  <text x="{left}" y="{y_cap}" text-anchor="middle" font-family="{FONT}" font-size="{cap}" fill="{c['sub']}">≈ paid apps per year</text>
  <text x="{mid}" y="{y_num - big * 0.2}" text-anchor="middle" font-family="{FONT}" font-size="{big * 0.6}" fill="{c['sub']}">→</text>
  <text x="{right}" y="{y_num}" text-anchor="middle" font-family="{FONT}" font-size="{big}" font-weight="700" fill="{green}">$0</text>
  <text x="{right}" y="{y_cap}" text-anchor="middle" font-family="{FONT}" font-size="{cap}" font-weight="600" fill="{c['ink']}">Whytap</text>
</svg>
'''


def section():
    rows = [o for o in offers() if o["access"] == "noCard"]
    order = list(CATEGORY)
    rows.sort(key=lambda o: order.index(o["category"]))  # stable: Swift order within a category
    newest = max(o["checked"] for o in rows)
    for old in OUT.glob("free-api-*.svg"):  # cards and banner
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
    for lay in BANNER:
        for t in THEMES:
            (OUT / f"free-api-banner-{lay}-{t}.svg").write_text(banner(t, lay))
    b = lambda lay, t: f"docs/assets/readme/free-api-banner-{lay}-{t}.svg"
    banner_html = (
        "<picture>"
        f'<source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{b("phone", "dark")}">'
        f'<source media="(max-width: 640px)" srcset="{b("phone", "light")}">'
        f'<source media="(prefers-color-scheme: dark)" srcset="{b("wide", "dark")}">'
        f'<source media="(prefers-color-scheme: light)" srcset="{b("wide", "light")}">'
        f'<img alt="Similar paid apps cost about {PAID_YEARLY} a year; Whytap is $0" src="{b("wide", "dark")}" width="{BANNER["wide"][0]}">'
        "</picture>"
    )
    return "\n".join([
        HEADING,
        "",
        f"<p align=\"center\">{banner_html}</p>",
        "",
        "<p align=\"center\">",
        "\n".join(cards),
        "</p>",
        "",
        "<p align=\"center\">Everyday use fits in the free quotas.<br>",
        f"<sub>No card needed · Reviewed monthly · Last checked {display(newest)}</sub></p>",
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
