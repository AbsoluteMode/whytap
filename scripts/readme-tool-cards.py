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

It rewrites docs/assets/readme/tool-tile-*.svg and the "## Tools" section of
README.md. When a card changes, rename the tile prefix: GitHub caches README
images for several minutes under the same URL.
"""
# WHY: .project-docs/decisions/2026-11-20-readme-tool-accordion.md
import re, sys, pathlib, html

REPO = pathlib.Path(__file__).resolve().parent.parent
LUCIDE = pathlib.Path(sys.argv[1])
OUT = REPO / "docs/assets/readme"
A = "docs/assets/readme"

# slug, Lucide icon, title, subtitle (alt text only), steps, description (wide card), media (list of files; Calendar has a reduced-motion still)
DEMOS = [
    ("drop-smart", "audio-lines", "Drop Smart", "Speak, correct yourself, release",
     ["Hold Space", "Speak", "Release to paste"],
     'Smart removes fillers and keeps your final wording; Fast pastes it as said. Use your own speech key or Parakeet v3 on Apple Silicon.', ["demo-drop-smart.webp"]),
    ("agent", "sparkles", "Agent", "Get an answer in the notch",
     ["Tap or hold the shortcut", "Ask", "Insert"],
     'Your chosen model with your own key. It can search the web, read local files and return cards you open or insert.', ["demo-agent.webp"]),
    ("case", "key-round", "Case", "Approve a command in the notch",
     ["Save a key", "Agent asks", "Allow or deny"],
     'Secrets stay on your Mac. Claude Code and Cursor see key names only; the value goes to the command you approve.', ["demo-case.webp"]),
    ("meetings", "notebook-pen", "Meeting Notes", "From a call to the next steps",
     ["Take notes", "End the call", "Get action items"],
     'Zoom, Meet, Teams and Slack without a bot in the call. Summary, action items and transcript, readable over MCP.', ["demo-meetings.webp"]),
    ("language-vocab", "languages", "Output Language & Vocab", "Set up dictation for the way you speak",
     ["Pick an output language", "Add your terms"],
     'Dictate in one language and paste in another. Teach Drop your project names, jargon and handles.', ["demo-output-lang.webp", "demo-vocab.webp"]),
    ("shot", "scan-text", "Shot", "Capture and edit a region",
     ["Select", "Annotate or blur", "Copy text"],
     'Arrows, shapes, text and auto-blur for text and numbers. Copy text recognizes text on your Mac.', ["demo-shot.webp"]),
    ("history", "history", "History", "Find something you used earlier",
     ["Open History", "Search", "Paste it again"],
     'Recent copies, dictations and Agent answers in one searchable list. Everything stays on your Mac.', ["demo-history.webp"]),
    ("notify-monitor", "bell-ring", "Notify & Monitor", "Keep an eye on your tools",
     ["Cards from agents, CI", "Live dashboards"],
     'Cards from Claude Code, Codex, CI or any script. Dashboards for your servers and your own data.', ["demo-notify.webp"]),
    ("calendar-todo", "calendar-check", "Calendar & To-do", "Check your agenda and manage tasks",
     ["Today's agenda", "Tasks in the notch"],
     'One agenda from your connected calendars. Coding agents can add tasks through the whytap CLI.', ["demo-calendar-todo.gif"]),
    ("display-extra", "sun-medium", "Display Extra", "Use the display’s available HDR headroom",
     ["Open Display", "Turn on Extra", "Slide"],
     "Brighter than the slider's maximum on XDR and HDR displays. Hold keeps your level when macOS changes it.", ["demo-brightness.webp"]),
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
    "wide": dict(dx=420, dwrap=48, dfs=13, dlh=18.5, W=860, H=92, rx=16, cx=46, r=26, isz=26, tx=92, ty=41, ts=18, py=64, ps=13.5,
                 pw=78, ph=32, pfs=14, pill_mid=True),
    "phone": dict(W=300, H=60, rx=12, cx=25, r=16, isz=18, tx=50, ty=26, ts=14, py=45, ps=11,
                  pw=44, ph=18, pfs=11, pill_mid=False),
}


def icon_inner(name):
    svg = (LUCIDE / f"{name}.svg").read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    return re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1).strip()


def desc_block(desc, c, g):
    if not g.get("dx"):
        return ""
    import textwrap
    lines = textwrap.wrap(desc, g["dwrap"])
    top = g["H"] / 2 - (len(lines) - 1) * g["dlh"] / 2 + g["dfs"] * 0.35
    spans = "".join(f'<tspan x="{g["dx"]}" y="{top + i * g["dlh"]:.1f}">{html.escape(l)}</tspan>' for i, l in enumerate(lines))
    return (f'  <line x1="{g["dx"]-22}" y1="18" x2="{g["dx"]-22}" y2="{g["H"]-18}" stroke="{c["border"]}"/>\n'
            f'  <text font-family="{FONT}" font-size="{g["dfs"]}" fill="{c["sub"]}">{spans}</text>')


def card(title, sub, steps, desc, icon, theme, layout):
    c, g = THEMES[theme], LAYOUTS[layout]
    W, H = g["W"], g["H"]
    sep = f'<tspan fill="{c["dot"]}">  ·  </tspan>'
    steps_svg = sep.join(f"<tspan>{html.escape(s)}</tspan>" for s in steps)
    sc = g["isz"] / 24
    if g["pill_mid"]:
        px, py = W - g["pw"] - 22, H / 2 - g["ph"] / 2
    else:
        px, py = W - g["pw"] - 8, 8
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="{g['rx']}" fill="{c['bg']}" stroke="{c['border']}"/>
  <circle cx="{g['cx']}" cy="{H/2}" r="{g['r']}" fill="{c['disk']}"/>
  <g transform="translate({g['cx']-g['isz']/2} {H/2-g['isz']/2}) scale({sc:.4f})" fill="none" stroke="{c['icon']}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{icon_inner(icon)}</g>
  <text x="{g['tx']}" y="{g['ty']}" font-family="{FONT}" font-size="{g['ts']}" font-weight="600" fill="{c['title']}">{html.escape(title)}</text>
  <text x="{g['tx']}" y="{g['py']}" font-family="{FONT}" font-size="{g['ps']}" font-weight="500" fill="{c['steps']}" xml:space="preserve">{steps_svg}</text>
{desc_block(desc, c, g)}
  <rect x="{px}" y="{py}" width="{g['pw']}" height="{g['ph']}" rx="{g['ph']/2}" fill="{c['pill']}"/>
  <text x="{px+g['pw']/2}" y="{py+g['ph']/2+g['pfs']*0.36:.1f}" text-anchor="middle" font-family="{FONT}" font-size="{g['pfs']}" font-weight="600" fill="{c['pilltext']}">Click</text>
</svg>
'''


def media_html(slug, files, title):
    alt = html.escape(f"{title} demo")
    if slug == "calendar-todo":
        return ("<picture>"
                f'<source media="(prefers-reduced-motion: reduce)" srcset="{A}/demo-calendar-todo-still.webp">'
                f'<img src="{A}/demo-calendar-todo.gif" width="88%" loading="lazy" alt="{alt}">'
                "</picture>")
    if len(files) == 1:
        return f'<img src="{A}/{files[0]}" width="88%" loading="lazy" alt="{alt}">'
    return "\n".join(f'<img src="{A}/{f}" width="43.5%" loading="lazy" alt="{alt}">' for f in files)


section = ["## Tools", "",
           "<sub>Click a tool to play its demo. Opening one closes the previous.</sub>", ""]
for slug, icon, title, sub, steps, desc, media in DEMOS:
    for t in THEMES:
        for lay in LAYOUTS:
            (OUT / f"tool-tile-{slug}-{lay}-{t}.svg").write_text(card(title, sub, steps, desc, icon, t, lay))
    alt = html.escape(f"{title}: {sub}")
    src = lambda lay, t: f"{A}/tool-tile-{slug}-{lay}-{t}.svg"
    section += [
        '<details name="tool-demo">',
        "<summary><picture>"
        f'<source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{src("phone","dark")}">'
        f'<source media="(max-width: 640px)" srcset="{src("phone","light")}">'
        f'<source media="(prefers-color-scheme: dark)" srcset="{src("wide","dark")}">'
        f'<source media="(prefers-color-scheme: light)" srcset="{src("wide","light")}">'
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
