#!/usr/bin/env python3
"""Write the README "Plugins" section: what to ask a coding agent, and the install line.

Six cards in one image as wide as the README column, three columns on wide
screens and two on phones (docs/assets/readme/plugin-grid-*.svg, dark and
light), show one request per thing a coding agent can do with Whytap: the
bundled plugin's meetings, To-do, models and Case key names, and the
agent-installed Notify sources and Monitor dashboards
(docs/customization/notifications.md, dashboards.md). Claude Code and Codex
appear as logos; each has its own code block that adds the
application-control server, so each copies on its own. Details and limits
stay in docs/customization/app-control.md.

Usage (icons come from Lucide, ISC, see docs/assets/readme/tool-icons.LICENSE.txt):
    npm pack lucide-static@0.460.0 && tar xzf lucide-static-0.460.0.tgz
    python3 scripts/readme-plugin-cards.py package/icons

The section goes after "## Tools". When a card changes, rename the file
prefix: GitHub caches README images for several minutes under the same URL.
"""
# WHY: .project-docs/decisions/2026-10-21-app-control-plugin.md
import html, pathlib, re, sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LUCIDE = pathlib.Path(sys.argv[1])
README = REPO / "README.md"
OUT = REPO / "docs/assets/readme"
A = "docs/assets/readme"
HEADING = "## Plugins"
HELPER = "/Applications/Whytap.app/Contents/Helpers/whytap"

# slug, Lucide icon, title, request (two lines), what holds it in check.
# Each request must be something the plugin's tools really do.
CARDS = [
    ("meetings", "notebook-pen", "Meetings", ["Where did we", "discuss pricing?"], "Asks you once"),
    ("todo", "list-checks", "To-do", ["Turn my last call", "into tasks"], "Saved to To-do"),
    ("notify", "bell-ring", "Notify", ["Tell me when", "CI fails"], "A local script"),
    ("monitor", "layout-dashboard", "Monitor", ["Build a dashboard", "for my server"], "Shown in Monitor"),
    ("models", "sliders-horizontal", "Models", ["Switch Drop Smart", "to a faster model"], "Checked like Settings"),
    ("case", "key-round", "Case", ["Deploy with", "my API key"], "Key names, never values"),
]
# Coding harnesses: logo file in Resources/UsefulLinkIcons, name, lockup width
# (logo + name, measured on GitHub), logo colour per theme
# (None = the theme's ink), and the line that adds the application-control server.
HARNESSES = [
    ("claude-code", "Claude Code", 106, {"dark": "#d97757", "light": "#d97757"},
     f"claude mcp add --scope user whytap -- {HELPER} app mcp"),
    ("codex", "Codex", 70, {"dark": None, "light": None},
     f"codex mcp add whytap -- {HELPER} app mcp"),
]
ICONS = REPO / "Resources/UsefulLinkIcons"

THEMES = {
    "dark": dict(bg="#151b23", border="#2d333b", ink="#f0f6fc", sub="#9198a1", accent="#b8adff"),
    "light": dict(bg="#f6f8fa", border="#d1d9e0", ink="#1f2328", sub="#59636e", accent="#5b4bd6"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
# The cards are one image as wide as the README column (like the code blocks
# below it), so its edges line up with them: three columns on wide screens,
# two on phones.
GRID = {
    "wide": dict(W=860, cols=3, gap=20, ch=112, pad=16, isz=18, ts=14, ty=28, qs=15, q0=57, ql=19, gs=12, gy=99),
    "phone": dict(W=300, cols=2, gap=10, ch=96, pad=11, isz=14, ts=12, ty=21, qs=11.5, q0=47, ql=15, gs=9.5, gy=85),
}


def icon_inner(name):
    svg = (LUCIDE / f"{name}.svg").read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    return re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1).strip()


def grid(theme, layout):
    c, g = THEMES[theme], GRID[layout]
    e = lambda t: html.escape(t, quote=False)
    cw = (g["W"] - g["gap"] * (g["cols"] - 1)) / g["cols"]
    rows = -(-len(CARDS) // g["cols"])
    h = rows * g["ch"] + (rows - 1) * g["gap"]
    out = []
    for i, (_, icon, title, lines, tag) in enumerate(CARDS):
        x = (i % g["cols"]) * (cw + g["gap"])
        y = (i // g["cols"]) * (g["ch"] + g["gap"])
        p = g["pad"]
        quote = [f"“{lines[0]}", f"{lines[1]}”"]
        spans = "".join(f'<tspan x="{x + p:.1f}" y="{y + g["q0"] + k * g["ql"]:.1f}">{e(l)}</tspan>' for k, l in enumerate(quote))
        out += [
            f'  <rect x="{x + 0.5:.1f}" y="{y + 0.5:.1f}" width="{cw - 1:.1f}" height="{g["ch"] - 1}" rx="12" fill="{c["bg"]}" stroke="{c["border"]}"/>',
            f'  <g transform="translate({x + p:.1f} {y + g["ty"] - g["isz"] * 0.8:.1f}) scale({g["isz"] / 24:.4f})" fill="none" stroke="{c["accent"]}" '
            f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{icon_inner(icon)}</g>',
            f'  <text x="{x + p + g["isz"] + 8:.1f}" y="{y + g["ty"]:.1f}" font-family="{FONT}" font-size="{g["ts"]}" font-weight="600" fill="{c["ink"]}">{e(title)}</text>',
            f'  <text font-family="{FONT}" font-size="{g["qs"]}" font-weight="500" fill="{c["ink"]}">{spans}</text>',
            f'  <text x="{x + p:.1f}" y="{y + g["gy"]:.1f}" font-family="{FONT}" font-size="{g["gs"]}" font-weight="600" fill="{c["accent"]}">{e(tag)}</text>',
        ]
    body = "\n".join(out)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{g['W']}" height="{h}" viewBox="0 0 {g['W']} {h}">
{body}
</svg>
'''


def lockup(asset, name, w, colors, theme):
    """The harness logo and its name, sized to sit in a line of README text."""
    c = THEMES[theme]
    color = colors[theme] or c["ink"]
    svg = (ICONS / f"{asset}.svg").read_text()
    svg = re.sub(r"<title>.*?</title>", "", svg, flags=re.S)
    svg = re.sub(r"#(?:111111|000000)", color, svg)
    if 'fill="' not in svg.split(">", 1)[0]:
        svg = svg.replace("<svg ", f'<svg fill="{color}" ', 1)
    svg = svg.replace("<svg ", '<svg x="0" y="2" width="16" height="16" ', 1)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="20" viewBox="0 0 {w} 20">
  {svg}
  <text x="22" y="15" font-family="{FONT}" font-size="14.5" font-weight="600" fill="{c['ink']}">{html.escape(name)}</text>
</svg>
'''


def themed(path, alt, width, extra=""):
    return ("<picture>"
            f'<source media="(prefers-color-scheme: dark)" srcset="{path("dark")}">'
            f'<source media="(prefers-color-scheme: light)" srcset="{path("light")}">'
            f'<img alt="{alt}" src="{path("dark")}" width="{width}"{extra}></picture>')


def section():
    for old in OUT.glob("plugin-*.svg"):
        old.unlink()
    for lay in GRID:
        for t in THEMES:
            (OUT / f"plugin-grid-{lay}-{t}.svg").write_text(grid(t, lay))
    alt = html.escape("; ".join(f"{title}: “{' '.join(lines)}” ({tag})" for _, _, title, lines, tag in CARDS))
    src = lambda lay, t: f"{A}/plugin-grid-{lay}-{t}.svg"
    cards = ("<picture>"
             f'<source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{src("phone", "dark")}">'
             f'<source media="(max-width: 640px)" srcset="{src("phone", "light")}">'
             f'<source media="(prefers-color-scheme: dark)" srcset="{src("wide", "dark")}">'
             f'<source media="(prefers-color-scheme: light)" srcset="{src("wide", "light")}">'
             f'<img alt="{alt}" src="{src("wide", "dark")}" width="100%"></picture>')
    logos, install = {}, []
    for asset, name, width, colors, command in HARNESSES:
        for t in THEMES:
            svg = lockup(asset, name, width, colors, t)
            (OUT / f"plugin-harness-{asset}-{t}.svg").write_text(svg)
        w = re.search(r'width="(\d+)"', svg).group(1)
        logos[asset] = themed(lambda t: f"{A}/plugin-harness-{asset}-{t}.svg", name, w, ' align="absmiddle"')
        install += [f"<p>{logos[asset]}</p>", "", "```bash", command, "```", ""]
    return "\n".join([
        HEADING,
        "",
        f'<p align="center">Ask {logos["claude-code"]} or {logos["codex"]} to work with Whytap for you.</p>',
        "",
        f'<p align="center">{cards}</p>',
        "",
        *install,
    ]).rstrip("\n") + "\n"


def updated(readme):
    new = section()
    if HEADING in readme:
        start = readme.index(HEADING)
    else:  # right after the Tools section
        tools = readme.index("## Tools")
        nxt = re.search(r"^## ", readme[tools + 3:], re.M)
        start = tools + 3 + nxt.start() if nxt else len(readme)
        if not nxt:
            return readme.rstrip("\n") + "\n\n" + new
        return readme[:start] + new + "\n" + readme[start:]
    nxt = re.search(r"^## ", readme[start + len(HEADING):], re.M)
    end = start + len(HEADING) + nxt.start() if nxt else len(readme)
    return readme[:start] + new + ("\n" + readme[end:] if nxt else "")


if __name__ == "__main__":
    current = README.read_text()
    result = updated(current)
    if "--check" in sys.argv:
        if result != current:
            sys.exit("README.md Plugins section is out of date: run scripts/readme-plugin-cards.py")
        print("README.md Plugins section is current")
    else:
        README.write_text(result)
        print("ok")
