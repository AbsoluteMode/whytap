#!/usr/bin/env python3
"""Write the README "Free to use" section from the app's API hints.

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
HEADING = "## Free to use"
OLD_HEADINGS = ["## Free to run", "## Free API keys"]  # renamed 2026-11-21; replaced in place
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
W, H = 196, 124  # phone card
WW, WH = 421, 92  # wide card: two per row, each 49% of the README column
ICONS = REPO / "Resources/UsefulLinkIcons"
OUT = REPO / "docs/assets/readme"


def logo(asset, color, x, y, size):
    svg = (ICONS / f"{asset}.svg").read_text()
    svg = re.sub(r"<title>.*?</title>", "", svg, flags=re.S)
    svg = re.sub(r"[ \t]+(?=\n)", "", svg)
    svg = re.sub(r"#(?:111111|000000)", color, svg)
    if 'fill="' not in svg.split(">", 1)[0]:
        svg = svg.replace("<svg ", f'<svg fill="{color}" ', 1)
    return svg.replace("<svg ", f'<svg x="{x}" y="{y}" width="{size}" height="{size}" ', 1)


def short(cadence):
    return cadence[5:] if cadence.startswith("free ") else cadence


def wide_card(o, theme):
    c = THEMES[theme]
    e = lambda t: html.escape(t, quote=False)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{WW}" height="{WH}" viewBox="0 0 {WW} {WH}">
  <rect x="0.5" y="0.5" width="{WW-1}" height="{WH-1}" rx="14" fill="{c['bg']}" stroke="{c['border']}"/>
  {logo(o["assetName"], c["ink"], 18, 20, 20)}
  <text x="47" y="36" font-family="{FONT}" font-size="15" font-weight="600" fill="{c['ink']}">{e(o['provider'])}</text>
  <text x="18" y="70" font-family="{FONT}" font-size="12" font-weight="600" fill="{c['accent']}">{e(CATEGORY[o['category']])}</text>
  <text x="{WW-18}" y="46" text-anchor="end" font-family="{FONT}" font-size="30" font-weight="700" fill="{c['ink']}">{e(o['allowance'])}</text>
  <text x="{WW-18}" y="70" text-anchor="end" font-family="{FONT}" font-size="12" fill="{c['sub']}">{e(short(o['cadence']))}</text>
</svg>
'''


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
WIDTH = {"wide": 860, "phone": 300}  # shown 100% wide, like the code blocks
QUOTAS = "Everyday use fits in the free quotas."
# Ways to run Whytap without paying for a subscription (CLAUDE.md: BYOK, the
# On this Mac speech model on Apple Silicon, OpenAI-compatible self-hosted
# servers for text and realtime speech). The phone banner uses shorter words.
WAYS = [
    dict(title="Your own keys", sub="BYOK, billed by the provider", phone_title="Own keys", phone_sub="BYOK"),
    dict(title="Local speech-to-text", sub="on this Mac, Apple Silicon", phone_title="Local STT", phone_sub="on this Mac"),
    dict(title="Self-hosted", sub="OpenAI-compatible servers", phone_title="Self-hosted", phone_sub="OpenAI-compatible"),
]


def facts(checked):
    """The banner's footer: what the free tier covers and how fresh the offers are."""
    return ["No card needed", "Reviewed monthly", f"Last checked {display(checked)}"]


def _text(x, y, size, fill, body, weight="400"):
    return (f'  <text x="{x}" y="{y}" text-anchor="middle" font-family="{FONT}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}">{html.escape(body, quote=False)}</text>')


def _box(w, h, c, body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
  <rect x="0.5" y="0.5" width="{w-1}" height="{h-1}" rx="16" fill="{c['bg']}" stroke="{c['border']}"/>
{body}
</svg>
'''


def arrow(x, y, length, color, width):
    """A drawn arrow: a text "→" looked thin and uneven when the banner is scaled."""
    head = length * 0.32
    x0, x1 = x - length / 2, x + length / 2
    return (f'  <path d="M{x0:.1f} {y:.1f} H{x1:.1f} M{x1 - head:.1f} {y - head:.1f} L{x1:.1f} {y:.1f} L{x1 - head:.1f} {y + head:.1f}" '
            f'fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>')


def banner(theme, layout, checked):
    # WHY: .project-docs/decisions/2026-11-21-free-api-report.md (2026-11-21
    # follow-ups: the ways to run free, the quota lines and the $600 → $0
    # comparison in one block, the comparison at its bottom).
    c = THEMES[theme]
    w = WIDTH[layout]
    wide = layout == "wide"
    mid = w / 2
    col = (w - 48) / 3
    rule = lambda y: f'  <line x1="24" y1="{y}" x2="{w - 24}" y2="{y}" stroke="{c["border"]}"/>'
    # Three ways to run free, in columns.
    y_way = 38 if wide else 28
    rows = []
    for i, way in enumerate(WAYS):
        x = 24 + col * (i + 0.5)
        rows.append(_text(x, y_way, 15 if wide else 11, c["ink"], way["title"] if wide else way["phone_title"], "600"))
        rows.append(_text(x, y_way + (21 if wide else 15), 13 if wide else 9.5, c["sub"], way["sub"] if wide else way["phone_sub"]))
    y_rule = y_way + (42 if wide else 31)
    rows.append(rule(y_rule))
    # The quota line, then one footer line (two on phones).
    items = facts(checked)
    lines = [" · ".join(items)] if wide else [" · ".join(items[:2]), items[2]]
    y_quota = y_rule + (34 if wide else 24)
    rows.append(_text(mid, y_quota, 16 if wide else 12, c["ink"], QUOTAS, "600"))
    step = 23 if wide else 16
    rows += [_text(mid, y_quota + step * (i + 1), 13.5 if wide else 10.5, c["sub"], line) for i, line in enumerate(lines)]
    y_rule2 = y_quota + step * len(lines) + (22 if wide else 16)
    rows.append(rule(y_rule2))
    # Similar paid apps a year, struck through, against $0 for Whytap.
    big, cap = (46, 14) if wide else (28, 10.5)
    left, right = w * 0.3, w * 0.7
    y_num = y_rule2 + (64 if wide else 44)
    y_cap = y_num + cap * 1.8
    green = "#3fb950" if theme == "dark" else "#1a7f37"
    rows += [
        _text(left, y_num, big, c["sub"], PAID_YEARLY, "700"),
        f'  <line x1="{left - big * 1.2:.1f}" y1="{y_num - big * 0.33:.1f}" x2="{left + big * 1.2:.1f}" y2="{y_num - big * 0.33:.1f}" '
        f'stroke="{c["sub"]}" stroke-width="{2.5 if wide else 2}" stroke-linecap="round"/>',
        _text(left, y_cap, cap, c["sub"], "≈ paid apps per year"),
        arrow(mid, y_num - big * 0.33, 44 if wide else 26, c["sub"], 2.5 if wide else 2),
        _text(right, y_num, big, green, "$0", "700"),
        _text(right, y_cap, cap, c["ink"], "Whytap", "600"),
    ]
    h = round(y_cap + (26 if wide else 18))
    return _box(w, h, c, "\n".join(rows))


def responsive(kind, alt, width):
    b = lambda lay, t: f"docs/assets/readme/free-api-{kind}-{lay}-{t}.svg"
    return (
        "<picture>"
        f'<source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{b("phone", "dark")}">'
        f'<source media="(max-width: 640px)" srcset="{b("phone", "light")}">'
        f'<source media="(prefers-color-scheme: dark)" srcset="{b("wide", "dark")}">'
        f'<source media="(prefers-color-scheme: light)" srcset="{b("wide", "light")}">'
        f'<img alt="{html.escape(alt)}" src="{b("wide", "dark")}" width="{width}">'
        "</picture>"
    )


# "My setup": the maintainer's own routes from Settings -> API & Models, free*
# because the language models are paid from a subscription's monthly API credit
# (the Claude Max & Ultra and ChatGPT Pro offers above in APIHintsView.hints)
# and speech from ElevenLabs' free credits. One panel per key, with OpenAI's
# model of the same price class in place of Claude's: on 2026-11-21 Maxim moved
# every text feature to Claude Sonnet 5.5, so each key has one model. He reviews
# and updates it every month together with the offers.
SETUP_CHECKED = "2026-11-21"
SPEECH = "Scribe v3 Live"
SETUP_ROWS = [  # feature, speech model, uses the key's language model
    ("Drop Fast", SPEECH, False),
    ("Drop Smart", SPEECH, True),
    ("Meetings", "Scribe v3", True),  # recorded audio, not the live model
    ("Agent", None, True),
    ("Agent voice", SPEECH, False),
    ("Voice search", SPEECH, False),
    ("Translation", None, True),
    ("Subtitles", SPEECH, True),
]
SETUP_KEYS = [  # logo, logo colour (None = ink), title, plan line (wide, phone), model
    ("claude-code", "#d97757", "Anthropic key",
     ("Claude Max or Ultra: $100–200 API credit a month", "Max or Ultra: $100–200 credit a month"),
     "Claude Sonnet 5.5"),
    ("openai", None, "OpenAI key",
     ("ChatGPT Pro: $100–500 API credit a month", "ChatGPT Pro: $100–500 credit a month"),
     "GPT-6.2 Sol"),
]
SETUP_FOOT = [
    "* The models are paid from your plan’s monthly API credit; speech uses",
    "ElevenLabs’ 10,000 free credits (non-commercial use).",
]


def setup_svg(theme, layout):
    c = THEMES[theme]
    wide = layout == "wide"
    w = WIDTH[layout]
    e = lambda t: html.escape(t, quote=False)
    gap, ph = 20, (58 if wide else 50)        # gap between panels, panel header height (title, plan line)
    pw = (w - gap) / 2 if wide else w          # panel width
    rh = 30 if wide else 24                    # row height
    fs, hs = (13.5, 15) if wide else (11, 12.5)
    col = (18, 132, 268) if wide else (12, 96, 192)
    top = 46 if wide else 40
    panel_h = ph + 26 + rh * len(SETUP_ROWS) + 10
    out = [
        f'  <text x="0" y="{22 if wide else 18}" font-family="{FONT}" font-size="{19 if wide else 15}" font-weight="700" fill="{c["ink"]}">My setup'
        f'<tspan dx="{10 if wide else 7}" font-size="{14 if wide else 11.5}" font-weight="600" fill="{c["accent"]}">free* right now</tspan></text>',
    ]
    for k, (asset, color, title, plan, model) in enumerate(SETUP_KEYS):
        x = k * (pw + gap) if wide else 0
        y = top if wide else top + k * (panel_h + 14)
        out.append(f'  <rect x="{x + 0.5:.1f}" y="{y + 0.5:.1f}" width="{pw - 1:.1f}" height="{panel_h - 1}" rx="14" fill="{c["bg"]}" stroke="{c["border"]}"/>')
        out.append("  " + logo(asset, color or c["ink"], round(x + col[0], 1), y + (13 if wide else 11), 18 if wide else 15))
        out.append(f'  <text x="{x + col[0] + (26 if wide else 22):.1f}" y="{y + (27 if wide else 23)}" font-family="{FONT}" font-size="{hs}" font-weight="600" fill="{c["ink"]}">{e(title)}</text>')
        out.append(f'  <text x="{x + col[0]:.1f}" y="{y + (48 if wide else 41)}" font-family="{FONT}" font-size="{fs - 1.5}" fill="{c["sub"]}">{e(plan[0] if wide else plan[1])}</text>')
        hy = y + ph + 16
        for cx, label in zip(col, ["Feature", "Speech · ElevenLabs", "Model"]):
            out.append(f'  <text x="{x + cx:.1f}" y="{hy}" font-family="{FONT}" font-size="{fs - 2.5}" font-weight="600" fill="{c["accent"]}">{e(label)}</text>')
        out.append(f'  <line x1="{x + col[0]:.1f}" y1="{hy + 8}" x2="{x + pw - col[0]:.1f}" y2="{hy + 8}" stroke="{c["border"]}"/>')
        for i, (feature, speech, uses_model) in enumerate(SETUP_ROWS):
            ry = hy + 8 + rh * (i + 1) - rh * 0.32
            cells = [(feature, c["ink"], "600"), (speech or "—", c["ink"] if speech else c["sub"], "400"),
                     (model if uses_model else "—", c["ink"] if uses_model else c["sub"], "400")]
            for cx, (text, fill, weight) in zip(col, cells):
                out.append(f'  <text x="{x + cx:.1f}" y="{ry:.1f}" font-family="{FONT}" font-size="{fs}" font-weight="{weight}" fill="{fill}">{e(text)}</text>')
    y = top + panel_h + 26 if wide else top + 2 * panel_h + 14 + 22
    foot = [" ".join(SETUP_FOOT), f"Updated monthly · Last checked {display(SETUP_CHECKED)}"] if wide else [
        "* The models are paid from your plan’s", "monthly API credit; speech uses ElevenLabs’",
        "10,000 free credits (non-commercial use).", f"Updated monthly · Last checked {display(SETUP_CHECKED)}"]
    for i, line in enumerate(foot):
        out.append(f'  <text x="0" y="{y + i * (20 if wide else 15)}" font-family="{FONT}" font-size="{12.5 if wide else 10.5}" fill="{c["sub"]}">{e(line)}</text>')
    h = y + (len(foot) - 1) * (20 if wide else 15) + 8
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h:.0f}" viewBox="0 0 {w} {h:.0f}">\n' + "\n".join(out) + "\n</svg>\n"


def setup_alt():
    parts = []
    for _, _, title, plan, model in SETUP_KEYS:
        rows = "; ".join(f"{f}: " + " + ".join(x for x in [s, model if m else None] if x) for f, s, m in SETUP_ROWS)
        parts.append(f"{title} ({plan[0]}): {rows}")
    return "My setup, free* right now. " + ". ".join(parts) + ". " + " ".join(SETUP_FOOT)


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
            (OUT / f"free-api-{slug}-wide-{t}.svg").write_text(wide_card(o, t))
        src = lambda t: f"docs/assets/readme/free-api-{slug}-{t}.svg"
        wsrc = lambda t: f"docs/assets/readme/free-api-{slug}-wide-{t}.svg"
        alt = html.escape(f"{o['provider']}: {o['allowance']} {o['cadence']} ({CATEGORY[o['category']]})")
        cards.append(
            f'<a href="{o["url"]}"><picture>'
            f'<source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{src("dark")}">'
            f'<source media="(max-width: 640px)" srcset="{src("light")}">'
            f'<source media="(prefers-color-scheme: dark)" srcset="{wsrc("dark")}">'
            f'<source media="(prefers-color-scheme: light)" srcset="{wsrc("light")}">'
            f'<img alt="{alt}" src="{wsrc("dark")}" width="49%"></picture></a>'
        )
    for lay in WIDTH:
        for t in THEMES:
            (OUT / f"free-api-summary-{lay}-{t}.svg").write_text(banner(t, lay, newest))
            (OUT / f"free-api-setup-{lay}-{t}.svg").write_text(setup_svg(t, lay))
    alt = ("; ".join(f"{way['title']} ({way['sub']})" for way in WAYS) + f". {QUOTAS} "
           + ", ".join(facts(newest)) + f". Similar paid apps cost about {PAID_YEARLY} a year; Whytap is $0.")
    return "\n".join([
        HEADING,
        "",
        f"<p align=\"center\">{responsive('summary', alt, '100%')}</p>",
        "",
        "<p align=\"center\">",
        "\n<br>\n".join("\n".join(cards[i:i + 2]) for i in range(0, len(cards), 2)),
        "</p>",
        "",
        f"<p align=\"center\">{responsive('setup', setup_alt(), '100%')}</p>",
    ]) + "\n"


def updated(readme):
    new = section()
    found = next((h for h in [HEADING, *OLD_HEADINGS] if h in readme), None)
    if found:
        start = readme.index(found)
        nxt = re.search(r"^## ", readme[start + len(found):], re.M)
        end = start + len(found) + nxt.start() if nxt else len(readme)
        tail = "\n" + readme[end:] if nxt else ""
        return readme[:start] + new + tail
    return readme.rstrip("\n") + "\n\n" + new


if __name__ == "__main__":
    current = README.read_text()
    result = updated(current)
    if "--check" in sys.argv:
        if result != current:
            sys.exit("README.md Free to use section is out of date: run scripts/readme-free-apis.py")
        print("README.md Free to use section is current")
    else:
        README.write_text(result)
        print("ok")
