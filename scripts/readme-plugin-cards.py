#!/usr/bin/env python3
"""Write the README "Plugins" section: what to ask a coding agent, and the install line.

Four small cards (docs/assets/readme/plugin-*.svg, dark and light) show one
request per area the bundled plugin serves (plugins/whytap: meetings, To-do,
models and settings, Case key names), then one code block installs the
application-control server for Claude Code and Codex. Details and limits stay
in docs/customization/app-control.md.

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
    ("models", "sliders-horizontal", "Models", ["Switch Drop Smart", "to a faster model"], "Checked like Settings"),
    ("case", "key-round", "Case", ["Deploy with", "my API key"], "Key names, never values"),
]

THEMES = {
    "dark": dict(bg="#151b23", border="#2d333b", ink="#f0f6fc", sub="#9198a1", accent="#b8adff"),
    "light": dict(bg="#f6f8fa", border="#d1d9e0", ink="#1f2328", sub="#59636e", accent="#5b4bd6"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
W, H = 196, 124


def icon_inner(name):
    svg = (LUCIDE / f"{name}.svg").read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    return re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1).strip()


def card(icon, title, lines, tag, theme):
    c = THEMES[theme]
    e = lambda t: html.escape(t, quote=False)
    quote = [f"“{lines[0]}", f"{lines[1]}”"]
    spans = "".join(f'<tspan x="16" y="{62 + i * 19}">{e(l)}</tspan>' for i, l in enumerate(quote))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="14" fill="{c['bg']}" stroke="{c['border']}"/>
  <g transform="translate(16 15) scale(0.75)" fill="none" stroke="{c['accent']}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{icon_inner(icon)}</g>
  <text x="42" y="29" font-family="{FONT}" font-size="14" font-weight="600" fill="{c['ink']}">{e(title)}</text>
  <text font-family="{FONT}" font-size="15" font-weight="500" fill="{c['ink']}">{spans}</text>
  <text x="16" y="110" font-family="{FONT}" font-size="11.5" font-weight="600" fill="{c['accent']}">{e(tag)}</text>
</svg>
'''


def section():
    for old in OUT.glob("plugin-*.svg"):
        old.unlink()
    cards = []
    for slug, icon, title, lines, tag in CARDS:
        for t in THEMES:
            (OUT / f"plugin-{slug}-{t}.svg").write_text(card(icon, title, lines, tag, t))
        src = lambda t: f"{A}/plugin-{slug}-{t}.svg"
        alt = html.escape(f"{title}: “{' '.join(lines)}” ({tag})")
        cards.append(
            "<picture>"
            f'<source media="(prefers-color-scheme: dark)" srcset="{src("dark")}">'
            f'<source media="(prefers-color-scheme: light)" srcset="{src("light")}">'
            f'<img alt="{alt}" src="{src("dark")}" width="{W}"></picture>'
        )
    return "\n".join([
        HEADING,
        "",
        '<p align="center">Ask Claude Code or Codex to work with Whytap for you.</p>',
        "",
        '<p align="center">',
        "\n".join(cards),
        "</p>",
        "",
        "```bash",
        "# Claude Code",
        f"claude mcp add --scope user whytap -- {HELPER} app mcp",
        "# Codex",
        f"codex mcp add whytap -- {HELPER} app mcp",
        "```",
        "",
        '<p align="center"><sub>Case keys: Whytap → Case → Connect · '
        '<a href="docs/customization/app-control.md">What the plugin can do</a></sub></p>',
    ]) + "\n"


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
