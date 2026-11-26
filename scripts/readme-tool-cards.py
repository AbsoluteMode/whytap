#!/usr/bin/env python3
"""Generate the README "Tools" section: one card per tool in an exclusive accordion.

GitHub README pages run no CSS or JavaScript, so each tool is a
<details name="tool-demo"> whose <summary> is a card image; browsers keep only
one such details element open. Cards are SVGs in four variants (wide/phone,
dark/light) chosen by <picture> media queries; the opened details shows only
the tool's motion video.

Usage (icons come from Lucide, ISC, see docs/assets/readme/tool-icons.LICENSE.txt):
    npm pack lucide-static@0.460.0 && tar xzf lucide-static-0.460.0.tgz
    python3 scripts/readme-tool-cards.py package/icons

It rewrites docs/assets/readme/tool-line-*.svg and the "## Tools" section of
README.md. When a card changes, rename the file prefix: GitHub caches README
images for several minutes under the same URL.
"""
# WHY: .project-docs/decisions/2026-11-20-readme-tool-accordion.md
import re, sys, pathlib, html

REPO = pathlib.Path(__file__).resolve().parent.parent
LUCIDE = pathlib.Path(sys.argv[1])
OUT = REPO / "docs/assets/readme"
A = "docs/assets/readme"

# Calendar was closed as Soon (AbsoluteMode/whytap#360) and released on
# 2026-11-22. Set this to True and rerun only if CalendarAvailability.shipped goes
# back to false. The slug changes with it, so GitHub's image cache cannot keep
# showing the old card.
CALENDAR_SOON = False
SOON = " (soon)" if CALENDAR_SOON else ""

# slug, Lucide icon, title, subtitle (alt text only), steps, description (wide card, one
# line: keep it under ~105 characters), media (a <name>-still.webp beside a file is its
# reduced-motion frame)
DEMOS = [
    ("drop-smart", "audio-lines", "Drop Smart", "Speak, correct yourself, release",
     ["Hold Space", "Speak", "Release to paste"],
     'Smart drops fillers and keeps your final wording; Fast pastes it as said. Your key or on-device Parakeet.', ["demo-drop-smart.webp"]),
    ("agent", "sparkles", "Agent", "Get an answer in the notch",
     ["Tap or hold the shortcut", "Ask", "Insert"],
     'Your model, your key. Searches the web, reads local files, returns cards you open or insert.', ["demo-agent.webp"]),
    ("case", "key-round", "Case", "Approve a command in the notch",
     ["Save a key", "Agent asks", "Allow or deny"],
     'Secrets stay on your Mac. Claude Code and Cursor see key names; values go only to approved commands.', ["demo-case.webp"]),
    ("meetings", "notebook-pen", "Meeting Notes", "From a call to the next steps",
     ["Take notes", "End the call", "Get action items"],
     'Zoom, Meet, Teams, Slack, no bot in the call. Summary, action items and transcript, readable over MCP.', ["demo-meetings.webp"]),
    ("language-vocab", "languages", "Output Language & Vocab", "Set up dictation for the way you speak",
     ["Pick an output language", "Add your terms"],
     'Dictate in one language and paste in another. Teach Drop your project names, jargon and handles.', ["demo-output-lang.webp", "demo-vocab.webp"]),
    ("shot", "scan-text", "Shot", "Capture and edit a region",
     ["Select", "Annotate or blur", "Copy text"],
     'Arrows, shapes, text and auto-blur for text and numbers. Copy text recognizes text on your Mac.', ["demo-shot.webp"]),
    ("history", "history", "History", "Find something you used earlier",
     ["Open History", "Search", "Paste it again"],
     'Recent copies, dictations and Agent answers in one searchable list. Everything stays on your Mac.', ["demo-history.webp"]),
    ("notify", "bell-ring", "Notify", "Get a card when something happens",
     ["Copy prompt", "Agent connects", "Cards arrive"],
     'Cards beside the island from CI, Claude Code, Codex or any script. Your agent connects the source.', ["demo-notify-agent.webp"]),
    ("monitor", "activity", "Monitor", "Watch live numbers in the notch",
     ["Copy prompt", "Agent builds it", "Live numbers"],
     'Dashboards in the notch for your servers or your own data, kept fresh by a collector your agent writes.', ["demo-monitor-agent.webp"]),
    ("todo-agenda" + ("-soon" if CALENDAR_SOON else ""), "list-todo", f"To-do & Calendar{SOON}", "Manage tasks and see your day",
     ["Tasks in the notch", "Today's agenda"],
     'Subtasks and statuses; agents add tasks via the whytap CLI.'
     + (" Your day in Calendar is coming soon." if CALENDAR_SOON else " Your day in Calendar under the island."), ["demo-todo.webp", "demo-calendar.webp"]),
    ("display-extra", "sun-medium", "Display Extra", "Use the display’s available HDR headroom",
     ["Open Display", "Turn on Extra", "Slide"],
     "Brighter than the slider's maximum on XDR and HDR displays. Hold keeps your level steady.", ["demo-brightness.webp"]),
]

THEMES = {
    "dark": dict(bg="#151b23", border="#2d333b", title="#f0f6fc", sub="#9198a1", steps="#b8adff",
                 dot="#5b5490", disk="#2a2350", icon="#b8adff", pill="#6c5ce7", pilltext="#ffffff"),
    "light": dict(bg="#f6f8fa", border="#d1d9e0", title="#1f2328", sub="#59636e", steps="#5b4bd6",
                  dot="#b3aae8", disk="#ece9ff", icon="#5b4bd6", pill="#6c5ce7", pilltext="#ffffff"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"

# Geometry per layout. Desktop is shown at 92% of the README column (~760 px), phone at ~290 px.
LAYOUTS = {
    # wide: title and steps on the first line, the description on one line below
    "wide": dict(inline=True, W=860, H=54, rx=12, cx=30, r=17, isz=18, tx=60, ty=23, ts=16, gap=14, ps=12.5,
                 dy=42, dfs=12, pw=64, ph=24, pfs=12, pill_mid=True),
    "phone": dict(W=300, H=44, rx=10, cx=21, r=13, isz=15, tx=41, ty=19, ts=13.5, py=34, ps=10.5,
                  pw=42, ph=17, pfs=10.5, pill_mid=False),
}


# A row sits after the summary's 17 px disclosure marker, so the widest row that
# still fits on the marker's line is (column - 17 px) / column. One percentage
# cannot reach the right edge of the cards and code blocks at every column width
# (93% already wrapped at a 320 px phone), so each GitHub column range gets the
# largest percentage that leaves about 3 px at its narrowest column. GitHub's
# column: viewport - 66 px up to 543 px, - 98 px to 767 px; from 768 px the file
# sidebar shrinks it to 406 px, and it stops growing at 838 px from 1280 px. The
# width on <source> sizes the row where the browser supports it; elsewhere the
# img's 92% is the fallback that fits everywhere.
WIDTHS = [  # viewport media, card layout, row width
    ("(max-width: 400px)", "phone", "92%"),
    ("(max-width: 640px)", "phone", "94%"),
    ("(max-width: 767px)", "wide", "96%"),
    ("(max-width: 1011px)", "wide", "95%"),
    ("(max-width: 1279px)", "wide", "96.5%"),
    ("", "wide", "97.5%"),
]


def icon_inner(name):
    svg = (LUCIDE / f"{name}.svg").read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    return re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1).strip()


def desc_line(desc, c, g):
    if not g.get("inline"):
        return ""
    return (f'  <text x="{g["tx"]}" y="{g["dy"]}" font-family="{FONT}" font-size="{g["dfs"]}" '
            f'fill="{c["sub"]}">{html.escape(desc)}</text>')


def card(title, sub, steps, desc, icon, theme, layout):
    c, g = THEMES[theme], LAYOUTS[layout]
    W, H = g["W"], g["H"]
    sep = f'<tspan fill="{c["dot"]}">  ·  </tspan>'
    steps_svg = sep.join(f"<tspan>{html.escape(s)}</tspan>" for s in steps)
    sc = g["isz"] / 24
    title_svg = html.escape(title)
    if g.get("inline"):  # steps follow the title on the same line
        head = (f'  <text x="{g["tx"]}" y="{g["ty"]}" font-family="{FONT}" xml:space="preserve">'
                f'<tspan font-size="{g["ts"]}" font-weight="600" fill="{c["title"]}">{title_svg}</tspan>'
                f'<tspan dx="{g["gap"]}" font-size="{g["ps"]}" font-weight="500" fill="{c["steps"]}">{steps_svg}</tspan></text>')
    else:
        head = (f'  <text x="{g["tx"]}" y="{g["ty"]}" font-family="{FONT}" font-size="{g["ts"]}" font-weight="600" fill="{c["title"]}">{title_svg}</text>\n'
                f'  <text x="{g["tx"]}" y="{g["py"]}" font-family="{FONT}" font-size="{g["ps"]}" font-weight="500" fill="{c["steps"]}" xml:space="preserve">{steps_svg}</text>')
    if g["pill_mid"]:
        px, py = W - g["pw"] - 16, H / 2 - g["ph"] / 2
    else:
        px, py = W - g["pw"] - 6, 5
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="{g['rx']}" fill="{c['bg']}" stroke="{c['border']}"/>
  <circle cx="{g['cx']}" cy="{H/2}" r="{g['r']}" fill="{c['disk']}"/>
  <g transform="translate({g['cx']-g['isz']/2} {H/2-g['isz']/2}) scale({sc:.4f})" fill="none" stroke="{c['icon']}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{icon_inner(icon)}</g>
{head}
{desc_line(desc, c, g)}
  <rect x="{px}" y="{py}" width="{g['pw']}" height="{g['ph']}" rx="{g['ph']/2}" fill="{c['pill']}"/>
  <text x="{px+g['pw']/2}" y="{py+g['ph']/2+g['pfs']*0.36:.1f}" text-anchor="middle" font-family="{FONT}" font-size="{g['pfs']}" font-weight="600" fill="{c['pilltext']}">Click</text>
</svg>
'''


def media_html(slug, files, title):
    alt = html.escape(f"{title} demo")
    width = "88%" if len(files) == 1 else "43.5%"

    def one(f):
        img = f'<img src="{A}/{f}" width="{width}" loading="lazy" alt="{alt}">'
        still = f.rsplit(".", 1)[0] + "-still.webp"
        if (OUT / still).exists():
            return ("<picture>"
                    f'<source media="(prefers-reduced-motion: reduce)" srcset="{A}/{still}">'
                    f"{img}</picture>")
        return img

    return "\n".join(one(f) for f in files)


section = ["## Tools", ""]
for slug, icon, title, sub, steps, desc, media in DEMOS:
    for t in THEMES:
        for lay in LAYOUTS:
            (OUT / f"tool-line-{slug}-{lay}-{t}.svg").write_text(card(title, sub, steps, desc, icon, t, lay))
    alt = html.escape(f"{title}: {sub}")
    src = lambda lay, t: f"{A}/tool-line-{slug}-{lay}-{t}.svg"
    sources = ""
    for viewport, lay, width in WIDTHS:
        dark = f"{viewport} and (prefers-color-scheme: dark)" if viewport else "(prefers-color-scheme: dark)"
        light = viewport or "(prefers-color-scheme: light)"
        sources += (f'<source media="{dark}" srcset="{src(lay, "dark")}" width="{width}">'
                    f'<source media="{light}" srcset="{src(lay, "light")}" width="{width}">')
    section += [
        '<details name="tool-demo">',
        "<summary><picture>" + sources +
        f'<img alt="{alt}" src="{src("wide","dark")}" width="92%" align="absmiddle">'
        "</picture></summary>",
        "",
        "<p></p>",
        "<p>&emsp;&emsp;" + media_html(slug, media, title),
        "</p>",
        "",
        "</details>",
        "",
    ]

readme = REPO / "README.md"
s = readme.read_text()
start = s.index("## Tools")
nxt = re.search(r"^## ", s[start + 3:], re.M)
end = start + 3 + nxt.start() if nxt else len(s)
readme.write_text(s[:start] + "\n".join(section).rstrip() + "\n" + ("\n" + s[end:] if nxt else ""))
print("ok")
