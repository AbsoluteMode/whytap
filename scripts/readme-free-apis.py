#!/usr/bin/env python3
"""Write the README "Free API keys" section from the app's API hints.

The offers live in one place, `APIHintsView.hints` in
Sources/Sidekey/Settings/APIAndModels/APIHintsView.swift, which Settings ->
API & Models -> API hints shows. This script lists the offers that need no
card (`access: .noCard`) as a table at the end of README.md, with each offer's
own check date and the newest one in the header line.

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


def section():
    rows = [o for o in offers() if o["access"] == "noCard"]
    order = list(CATEGORY)
    rows.sort(key=lambda o: order.index(o["category"]))  # stable: Swift order within a category
    newest = max(o["checked"] for o in rows)
    esc = lambda t: html.escape(t, quote=False).replace("|", "\\|")
    lines = [
        HEADING,
        "",
        "Whytap is free: you bring the keys. These providers give an allowance without a card,",
        "so you can try Whytap without spending anything. The same list is in",
        "Settings → API & Models → API hints.",
        "",
        f"<sub>Reviewed monthly · Last checked {display(newest)}</sub>",
        "",
        "| For | Provider | Free allowance | Good to know | Checked |",
        "|---|---|---|---|---|",
    ]
    for o in rows:
        lines.append(
            f"| {CATEGORY[o['category']]} | [{esc(o['provider'])}]({o['url']}) "
            f"| **{esc(o['allowance'])}** {esc(o['cadence'])} | {esc(o['detail'])} | {display(o['checked'])} |"
        )
    lines += ["", "Allowances and terms belong to the providers and can change; check the linked page before you rely on one."]
    return "\n".join(lines) + "\n"


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
