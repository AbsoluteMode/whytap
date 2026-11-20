#!/usr/bin/env python3
"""Local Whytap source-change helpers. Standard library only; no shell execution."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
GUIDANCE = (".project-docs/agent-context.md", "AGENTS.md", "CLAUDE.md")
TOPICS = {
    "overview": "docs/customization/README.md",
    "hover": "docs/customization/hover-tools.md",
    "dashboard": "docs/customization/dashboards.md",
    "data": "docs/customization/local-data.md",
}
RESERVED_SWIFT = {
    "actor", "as", "associatedtype", "break", "case", "catch", "class", "continue",
    "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
    "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
    "inout", "internal", "is", "let", "nil", "open", "operator", "private",
    "protocol", "public", "repeat", "rethrows", "return", "self", "static",
    "struct", "subscript", "super", "switch", "throw", "throws", "true",
    "try", "typealias", "var", "where", "while",
}


def read_regular(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular, non-symlink file: {path.relative_to(ROOT)}")
    return path.read_bytes()


def capabilities() -> dict:
    return json.loads(read_regular(ROOT / "tools/customization/capabilities.json"))


def display(value: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, indent=2, ensure_ascii=False))
    else:
        for key, item in value.items():
            print(f"{key}: {json.dumps(item, ensure_ascii=False) if isinstance(item, (dict, list)) else item}")


def discover(args: argparse.Namespace) -> int:
    info = capabilities()
    for topic in info["change_kinds"].values():
        topic["missing_entry_points"] = [name for name in topic["entry_points"] if not (ROOT / name).is_file()]
    display(info, args.json)
    return 0


def probe(command: list[str]) -> str | None:
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def guidance_status() -> dict:
    contents = {name: read_regular(ROOT / name) for name in GUIDANCE}
    return {
        "synchronized": len(set(contents.values())) == 1,
        "files": {name: {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)} for name, data in contents.items()},
    }


def doctor(args: argparse.Namespace) -> int:
    checks = []
    def check(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": ok, "detail": detail})
    check("macOS", sys.platform == "darwin", platform.mac_ver()[0] or platform.system())
    swift = probe(["swift", "--version"])
    version = re.search(r"Swift version (\d+)\.(\d+)", swift or "")
    check("Swift 6+", bool(version and int(version[1]) >= 6), (swift or "Install Xcode 16+ and select its developer directory").splitlines()[0])
    sdk = probe(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    version = re.match(r"(\d+)\.(\d+)", sdk or "")
    check("macOS SDK 14.2+", bool(version and (int(version[1]), int(version[2])) >= (14, 2)), sdk or "Xcode macOS SDK unavailable")
    for name in ("git", "codesign", "xcrun"):
        check(name, shutil.which(name) is not None, "available" if shutil.which(name) else "missing")
    try:
        status = guidance_status()
        check("agent guidance", status["synchronized"], "byte-identical" if status["synchronized"] else "Run sync-guidance --write")
    except ValueError as error:
        check("agent guidance", False, str(error))
    for name in ("Package.swift", "Package.resolved", "scripts/dev-run.sh", "Resources/Info.plist.template"):
        check(name, (ROOT / name).is_file(), "present" if (ROOT / name).is_file() else "missing")
    missing = sorted({path for topic in capabilities()["change_kinds"].values() for path in topic["entry_points"] if not (ROOT / path).is_file()})
    check("capability entry points", not missing, "current" if not missing else "Missing: " + ", ".join(missing))
    display({"ready": all(item["ok"] for item in checks), "checks": checks}, args.json)
    return 0 if all(item["ok"] for item in checks) else 1


def run_command(args: argparse.Namespace) -> int:
    if args.command == "build":
        command = ["/bin/bash", str(ROOT / "scripts/dev-run.sh")]
    elif args.command == "run":
        command = ["/bin/bash", str(ROOT / "scripts/dev-run.sh"), "--run"]
    else:
        command = ["swift", "test"]
        if args.filter:
            command.extend(["--filter", args.filter])
    print("Command: " + shlex.join(command), flush=True)
    if args.dry_run:
        return 0
    # Inherit the terminal so Swift progress and test failures remain visible.
    # Arguments are never interpreted by a shell.
    return subprocess.run(command, cwd=ROOT).returncode


def sync_guidance(args: argparse.Namespace) -> int:
    status = guidance_status()
    if args.write and not status["synchronized"]:
        source = read_regular(ROOT / GUIDANCE[0])
        for name in GUIDANCE[1:]:
            destination = ROOT / name
            read_regular(destination)  # Refuse symlinks; never merge generated edits.
            destination.write_bytes(source)
        status = guidance_status()
    display(status, args.json)
    return 0 if status["synchronized"] else 1


def identifier(raw: str, swift: bool = False) -> str:
    pattern = r"[a-z][A-Za-z0-9]{0,47}" if swift else r"[a-z][a-z0-9-]{0,63}"
    if not re.fullmatch(pattern, raw) or (swift and raw in RESERVED_SWIFT):
        raise ValueError("Use a lowercase-leading camelCase Swift identifier" if swift else "Use a lowercase dashboard ID containing letters, digits or hyphens")
    return raw


def title(raw: str) -> str:
    if not raw.strip() or len(raw) > 80 or any(ord(char) < 32 or ord(char) == 127 for char in raw):
        raise ValueError("Title must contain 1–80 printable characters")
    return raw.strip()


def make_output(raw: str | None, name: str) -> Path:
    # Generated drafts stay under an explicit directory; source files are never
    # edited automatically. Refuse existing destinations and symlink parents.
    destination = Path(raw).expanduser().absolute() if raw else ROOT / "build/customization-scaffolds" / name
    for parent in (destination, *destination.parents):
        if parent.is_symlink():
            raise ValueError("Refusing a symlink output path")
    if destination.exists():
        raise ValueError("Output already exists; choose a new directory")
    destination.mkdir(parents=True, mode=0o700)
    return destination


def scaffold_hover(args: argparse.Namespace) -> int:
    tool_id = identifier(args.id, swift=True)
    tool_title = title(args.title)
    enum = read_regular(ROOT / "Sources/Sidekey/Settings/HoverTool.swift").decode()
    if re.search(r"^\s*case\s+" + re.escape(tool_id) + r"\b", enum, re.MULTILINE):
        raise ValueError("A hover tool with this identifier already exists")
    destination = make_output(args.output, tool_id)
    view_name = tool_id[0].upper() + tool_id[1:] + "Content"
    (destination / f"{view_name}.swift").write_text(
        "import SwiftUI\n\n"
        "// Draft: copy into Sources/Sidekey only after completing the wiring checklist.\n"
        f"struct {view_name}: View {{\n"
        "    var body: some View {\n"
        f"        Text({json.dumps(tool_title, ensure_ascii=False)})\n"
        "            .padding()\n"
        "    }\n"
        "}\n", encoding="utf-8")
    manifest = {"tool_id": tool_id, "title": tool_title, "state": "draft-not-installed", "change_kind": "hover", "guide": TOPICS["hover"], "entry_points": capabilities()["change_kinds"]["hover"]["entry_points"]}
    (destination / "integration.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (destination / "README.md").write_text(
        f"# {tool_title}\n\n"
        "This draft is not installed in the app. Follow `docs/customization/hover-tools.md`.\n\n"
        f"1. Add persisted `HoverTool.{tool_id}` and registry metadata.\n"
        "2. Choose an existing inline panel, action or Settings destination; wire the shared router.\n"
        "3. Wire production handlers and preview no-ops; update exhaustive switches.\n"
        "4. Verify tile and feature hotkey dispatch and dynamic row height.\n"
        "5. Run focused checks, build the beta app, inspect it, then review the diff.\n\n"
        "No application source or user preferences were changed by the generator.\n", encoding="utf-8")
    print(f"Created draft: {destination}")
    return 0


def scaffold_dashboard(args: argparse.Namespace) -> int:
    dashboard_id = identifier(args.id)
    if dashboard_id == "server-status":
        raise ValueError("server-status is reserved for the built-in dashboard; use a custom ID")
    dashboard_title = title(args.title)
    destination = make_output(args.output, dashboard_id)
    snapshot = {
        "id": dashboard_id, "title": dashboard_title,
        "subtitle": "Connect a collector to receive live data",
        "systemImage": "server.rack", "preferredWidth": 720,
        "preferredHeight": 520, "staleAfterSeconds": 60,
        "widgets": [{"id": "connection", "kind": "status", "title": "Collector", "value": "Not connected", "status": "unknown", "detail": "No server addresses or credentials are included"}],
    }
    (destination / f"{dashboard_id}.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    (destination / "README.md").write_text(
        f"# {dashboard_title}\n\n"
        "This is an unconnected dashboard snapshot. It contains no live server data.\n"
        "Follow `docs/customization/dashboards.md` to connect a collector and install it.\n"
        "Keep private host aliases, credentials and snapshots outside the source repository.\n", encoding="utf-8")
    print(f"Created dashboard draft: {destination}")
    return 0


def validate_dashboard(path: Path) -> tuple[dict, bytes]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Dashboard must be a regular, non-symlink file")
    with path.open("rb") as stream:
        data = stream.read(2_000_001)
    if len(data) > 2_000_000:
        raise ValueError("Dashboard exceeds the 2 MB limit")
    snapshot = json.loads(data, parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Non-finite JSON number")))
    def require(condition: bool, message: str) -> None:
        if not condition:
            raise ValueError(message)
    def text_value(value: object, limit: int | None = None) -> bool:
        return isinstance(value, str) and (limit is None or len(value) <= limit)
    def valid_id(value: object) -> bool:
        return isinstance(value, str) and len(value) <= 120 and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) is not None
    def numeric(value: object) -> bool:
        return type(value) in (int, float) and math.isfinite(value)
    require(isinstance(snapshot, dict), "Dashboard must be a JSON object")
    require(valid_id(snapshot.get("id")) and snapshot["id"] != "server-status", "Invalid or reserved dashboard ID")
    require(text_value(snapshot.get("title"), 200) and bool(snapshot["title"].strip()), "Invalid dashboard title")
    for field, default, minimum, maximum in (("preferredWidth", 440, 320, 1200), ("preferredHeight", 560, 360, 1200), ("staleAfterSeconds", 60, 5, 86400)):
        value = snapshot.get(field)
        value = default if value is None else value
        require(numeric(value) and minimum <= value <= maximum, f"Invalid {field}")
    for field in ("subtitle", "systemImage", "accentHex"):
        value = snapshot.get(field)
        require(value is None or text_value(value, 1000 if field == "subtitle" else None), f"Invalid {field}")
    timestamp = snapshot.get("updatedAt")
    if timestamp is not None:
        require(isinstance(timestamp, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})", timestamp) is not None, "updatedAt must be an ISO 8601 timestamp with seconds and timezone")
        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError("Invalid updatedAt timestamp") from error
    widgets = snapshot.get("widgets")
    require(isinstance(widgets, list) and 1 <= len(widgets) <= 128, "Use 1–128 widgets")
    ids = set()
    for widget in widgets:
        require(isinstance(widget, dict), "Widget must be an object")
        widget_id = widget.get("id")
        require(valid_id(widget_id) and widget_id not in ids, "Invalid or duplicate widget ID")
        ids.add(widget_id)
        require(widget.get("kind") in ("metric", "progress", "status", "text", "chart"), "Unknown widget kind")
        require(text_value(widget.get("title"), 200) and bool(widget["title"]), "Invalid widget title")
        for field in ("value", "unit", "detail", "status", "accentHex"):
            value = widget.get(field)
            require(value is None or text_value(value, 20000 if field in ("value", "detail") else None), f"Invalid widget {field}")
        for field in ("progress", "trendPercent"):
            value = widget.get(field)
            require(value is None or numeric(value), f"Invalid widget {field}")
            if field == "progress" and value is not None:
                require(0 <= value <= 1, "Widget progress must be between 0 and 1")
        points = widget.get("points")
        if points is not None:
            require(isinstance(points, list) and len(points) <= 512, "Use at most 512 chart points")
            for point in points:
                require(isinstance(point, dict) and text_value(point.get("label"), 200) and numeric(point.get("value")), "Invalid chart point")
    return snapshot, data


def dashboard_command(args: argparse.Namespace) -> int:
    snapshot, data = validate_dashboard(Path(args.path).expanduser())
    if args.command == "validate-dashboard":
        print(f"Valid dashboard: {snapshot['id']} ({len(snapshot['widgets'])} widgets)")
        return 0
    bundle_id = "com.rootwise.sidekey" + (".beta" if args.flavor == "beta" else "")
    directory = Path.home() / "Library/Application Support" / bundle_id / "Monitor/dashboards"
    for parent in (directory, *directory.parents):
        if parent.is_symlink():
            raise ValueError("Refusing a symlink installation path")
    destination = directory / f"{snapshot['id']}.json"
    if destination.is_symlink():
        raise ValueError("Refusing a symlink dashboard destination")
    if destination.exists() and not args.replace:
        raise ValueError("Dashboard already exists; inspect it before using --replace")
    if args.dry_run:
        print(f"Would install {snapshot['id']} to {args.flavor} Monitor/dashboards/{destination.name}")
        return 0
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".dashboard-", delete=False) as stream:
            temporary_path = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if args.replace:
            os.replace(temporary_path, destination)
        else:
            # Hard-link installation refuses an existing destination atomically.
            os.link(temporary_path, destination)
            temporary_path.unlink()
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    print(f"Installed dashboard {snapshot['id']} for {args.flavor}; open Monitor to view it")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name, function in (("discover", discover), ("doctor", doctor)):
        child = subparsers.add_parser(name)
        child.add_argument("--json", action="store_true")
        child.set_defaults(function=function)
    child = subparsers.add_parser("context", help="Print one focused change guide")
    child.add_argument("topic", choices=TOPICS, default="overview", nargs="?")
    child.set_defaults(function=lambda args: print(read_regular(ROOT / TOPICS[args.topic]).decode()) or 0)
    for name in ("build", "run", "test"):
        child = subparsers.add_parser(name)
        child.add_argument("--dry-run", action="store_true")
        if name == "test":
            child.add_argument("--filter", help="Swift test suite, method or regular expression")
        child.set_defaults(function=run_command)
    child = subparsers.add_parser("sync-guidance")
    group = child.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="Default: report drift without editing")
    group.add_argument("--write", action="store_true", help="Regenerate AGENTS.md and CLAUDE.md from canonical guidance")
    child.add_argument("--json", action="store_true")
    child.set_defaults(function=sync_guidance)
    for name, function in (("scaffold-hover", scaffold_hover), ("scaffold-dashboard", scaffold_dashboard)):
        child = subparsers.add_parser(name)
        child.add_argument("--id", required=True)
        child.add_argument("--title", required=True)
        child.add_argument("--output", help="New draft directory; default: build/customization-scaffolds/<id>")
        child.set_defaults(function=function)
    for name in ("validate-dashboard", "install-dashboard"):
        child = subparsers.add_parser(name)
        child.add_argument("path", help="Local JSON snapshot")
        if name == "install-dashboard":
            child.add_argument("--flavor", choices=("prod", "beta"), default="beta")
            child.add_argument("--replace", action="store_true", help="Replace an existing dashboard with the same ID")
            child.add_argument("--dry-run", action="store_true")
        child.set_defaults(function=dashboard_command)
    args = parser.parse_args(argv)
    try:
        return args.function(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
