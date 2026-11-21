#!/usr/bin/env python3
"""Write the README "You may also like" cards: other AbsoluteMode projects.

Four cards in a 2x2 grid, the same look as the Free to use cards (two per row,
49% of the README column each): the name, who it works with, a
short description, and an arrow for a linked repository or a "soon" pill.
No icons: the projects have no logos of their own, and Maxim found generic
ones worse than none (2026-11-21).
GitHub strips CSS from READMEs, so each card is an SVG in dark and light
(docs/assets/readme/project-*.svg) chosen by <picture> and prefers-color-scheme.
Lines are wrapped by hand so the cards look the same on every machine; the
phone cards carry the same meaning in shorter lines. The alt text repeats the
wide card's text.

Usage:
    python3 scripts/readme-project-cards.py
"""
import html, pathlib, sys

REPO = pathlib.Path(__file__).resolve().parent.parent
README = REPO / "README.md"
OUT = REPO / "docs/assets/readme"
HEADING = "## You may also like"
FOOTER = '<p align="center"><sub>'  # the footer links that follow the section

# slug, name, URL (None: not published yet, shown as soon),
# wide: (who, [description lines]), phone: ([who lines], [description lines])
PROJECTS = [
    ("session-recall", "Session Recall", "https://github.com/AbsoluteMode/session-recall",
     ("Claude Code · Codex · Cursor · Antigravity",
      ["Shared semantic memory: find an old decision by meaning",
       "across all your agents' chats, with links to the original turns."]),
     (["Claude Code · Codex ·", "Cursor · Antigravity"],
      ["Shared semantic memory:", "find an old decision by", "meaning in all your", "agents' chats."])),
    ("flora", "flora", "https://github.com/AbsoluteMode/flora",
     ("Workflow contracts for coding harnesses",
      ["Every step says what proves it is done, and an independent",
       "verifier checks that before the next step starts."]),
     (["Workflow contracts for", "coding harnesses"],
      ["Every step says what", "proves it is done; a", "verifier checks it before", "the next step starts."])),
    ("harness-link", "Harness Link", "https://github.com/AbsoluteMode/harness-link",
     ("Claude Code · Codex · Antigravity",
      ["Connects their sessions: shared rooms, addressed messages",
       "to running sessions and persistent Claude consultations."]),
     (["Claude Code · Codex ·", "Antigravity"],
      ["Shared rooms, messages", "to running sessions and", "persistent Claude", "consultations."])),
    ("orchestrator", "Orchestrator", None,
     ("Claude Code plugin",
      ["Ten chats in one window: it keeps the task list, starts the",
       "sessions and writes to you only when it needs you."]),
     (["Claude Code plugin"],
      ["Ten chats in one window:", "it keeps the task list", "and writes to you only", "when it needs you."])),
]

THEMES = {  # the Tools and Free to use cards' palette
    "dark": dict(bg="#151b23", border="#2d333b", title="#f0f6fc", sub="#9198a1", accent="#b8adff",
                 pill="#6c5ce7", pilltext="#ffffff"),
    "light": dict(bg="#f6f8fa", border="#d1d9e0", title="#1f2328", sub="#59636e", accent="#5b4bd6",
                  pill="#6c5ce7", pilltext="#ffffff"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
LAYOUTS = {
    # wide: two per row at 49% of the README column from 641 px up
    "wide": dict(W=421, H=112, rx=14, x=18, ty=34, ts=16, hy=29,
                 ay=58, afs=12.5, astep=0, dy=80, dfs=12.5, dstep=18,
                 arrow=16, pw=44, ph=20, pfs=11.5),
    # phone: the same two columns on a narrow column, so shorter lines
    "phone": dict(W=196, H=158, rx=14, x=16, ty=31, ts=14.5, hy=26,
                  ay=54, afs=11.5, astep=15, dy=92, dfs=12, dstep=16,
                  arrow=14, pw=38, ph=18, pfs=10.5),
}
# Lucide arrow-up-right (ISC, see docs/assets/readme/tool-icons.LICENSE.txt)
ARROW = '<path d="M7 7h10v10"/><path d="M7 17 17 7"/>'


def text(x, y, size, fill, body, weight="400", anchor="start"):
    return (f'  <text x="{x}" y="{y}" text-anchor="{anchor}" font-family="{FONT}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}">{html.escape(body, quote=False)}</text>')


def card(project, theme, layout):
    slug, name, url, wide, phone = project
    c, g = THEMES[theme], LAYOUTS[layout]
    W, H, x = g["W"], g["H"], g["x"]
    who, desc = (([wide[0]], wide[1]) if layout == "wide" else phone)
    rows = [
        f'  <rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="{g["rx"]}" fill="{c["bg"]}" stroke="{c["border"]}"/>',
        text(x, g["ty"], g["ts"], c["title"], name, "600"),
    ]
    right = W - 16
    if url:  # a drawn arrow to the repository, like a link mark
        a = g["arrow"]
        rows.append(f'  <g transform="translate({right - a} {g["hy"] - a / 2}) scale({a / 24:.4f})" fill="none" '
                    f'stroke="{c["sub"]}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{ARROW}</g>')
    else:  # not published yet: a pill where the arrow would be
        px, py = right - g["pw"], g["hy"] - g["ph"] / 2
        rows.append(f'  <rect x="{px}" y="{py}" width="{g["pw"]}" height="{g["ph"]}" rx="{g["ph"]/2}" fill="{c["pill"]}"/>')
        rows.append(text(px + g["pw"] / 2, f'{py + g["ph"]/2 + g["pfs"]*0.36:.1f}', g["pfs"], c["pilltext"], "soon", "600", "middle"))
    rows += [text(x, g["ay"] + i * g["astep"], g["afs"], c["accent"], line, "600") for i, line in enumerate(who)]
    rows += [text(x, g["dy"] + i * g["dstep"], g["dfs"], c["sub"], line) for i, line in enumerate(desc)]
    body = "\n".join(rows)
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">\n{body}\n</svg>\n'


def alt(project):
    slug, name, url, wide, phone = project
    soon = "" if url else " (soon)"
    return f"{name}{soon}: {wide[0]}. {' '.join(wide[1])}"


def picture(project):
    slug = project[0]
    f = lambda lay, t: f"docs/assets/readme/project-{slug}-{lay}-{t}.svg"
    img = (f'<picture><source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{f("phone", "dark")}">'
           f'<source media="(max-width: 640px)" srcset="{f("phone", "light")}">'
           f'<source media="(prefers-color-scheme: dark)" srcset="{f("wide", "dark")}">'
           f'<source media="(prefers-color-scheme: light)" srcset="{f("wide", "light")}">'
           f'<img alt="{html.escape(alt(project), quote=False).replace(chr(34), '&quot;')}" src="{f("wide", "dark")}" width="49%"></picture>')
    return f'<a href="{project[2]}">{img}</a>' if project[2] else img


def section():
    rows = [picture(p) for p in PROJECTS]
    return f'{HEADING}\n\n<p align="center">\n{rows[0]}\n{rows[1]}\n<br>\n{rows[2]}\n{rows[3]}\n</p>\n\n'


def main():
    if len(sys.argv) != 1:
        sys.exit(__doc__)
    for p in PROJECTS:
        for lay in LAYOUTS:
            for t in THEMES:
                (OUT / f"project-{p[0]}-{lay}-{t}.svg").write_text(card(p, t, lay))
    readme = README.read_text()
    start, end = readme.index(HEADING), readme.index(FOOTER)
    README.write_text(readme[:start] + section() + readme[end:])


if __name__ == "__main__":
    main()
