#!/usr/bin/env python3
"""Write and verify the install window without a running Finder session."""

import argparse
import hashlib
import sys
from pathlib import Path

# Pinned, unmodified MIT libraries; no pip/network dependency on the builder.
sys.path.insert(0, str(Path(__file__).resolve().parent / "_vendor"))
from ds_store import DSStore
from mac_alias import Alias


BACKGROUND = Path(".background/background.png")
WINDOW = {
    "WindowBounds": "{{400, 100}, {660, 440}}",
    "ShowStatusBar": False,
    "ShowTabView": False,
    "ShowToolbar": False,
    "ShowPathbar": False,
    "ShowSidebar": False,
    "ContainerShowSidebar": False,
    "PreviewPaneVisibility": False,
    "SidebarWidth": 0,
}
ICONS = {
    "viewOptionsVersion": 1,
    "backgroundType": 2,
    "backgroundColorRed": 1.0,
    "backgroundColorGreen": 1.0,
    "backgroundColorBlue": 1.0,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "arrangeBy": "none",
    "showIconPreview": True,
    "showItemInfo": False,
    "labelOnBottom": True,
    "textSize": 13.0,
    "iconSize": 128.0,
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_contents(volume, app_name, background_source):
    require(Path(app_name).name == app_name and app_name.endswith(".app"),
            "app name must be one .app filename")
    require(volume.is_dir(), "DMG volume is missing")
    require((volume / app_name).is_dir(), "DMG app is missing")
    applications = volume / "Applications"
    require(applications.is_symlink() and str(applications.readlink()) == "/Applications",
            "DMG Applications must link to /Applications")
    background = volume / BACKGROUND
    require(background.is_file() and not background.is_symlink(),
            "DMG background is missing")
    require(hashlib.sha256(background.read_bytes()).digest() ==
            hashlib.sha256(background_source.read_bytes()).digest(),
            "DMG background differs from the committed source")
    return background


def write_layout(volume, app_name, background_source):
    background = check_contents(volume, app_name, background_source)
    # Generate on the mounted HFS+ image: its file IDs and volume creation date
    # survive compression/remounting, unlike an alias made in the staging dir.
    alias = Alias.for_file(str(background.resolve()))
    with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = WINDOW
        store["."]["icvp"] = dict(ICONS, backgroundImageAlias=alias.to_bytes())
        store["."]["icvl"] = ("type", b"icnv")
        store[app_name]["Iloc"] = (180, 220)
        store["Applications"]["Iloc"] = (480, 220)
    verify_layout(volume, app_name, background_source)


def verify_layout(volume, app_name, background_source):
    background = check_contents(volume, app_name, background_source)
    ds_store = volume / ".DS_Store"
    require(ds_store.is_file() and not ds_store.is_symlink(),
            "DMG Finder layout (.DS_Store) is missing")
    with DSStore.open(str(ds_store), "r") as store:
        require(store["."]["icvl"] == (b"type", b"icnv"),
                "DMG default view is not icon view")
        window = store["."]["bwsp"]
        icons = store["."]["icvp"]
        require(all(window.get(key) == value for key, value in WINDOW.items()),
                "DMG window bounds or chrome changed")
        require(all(icons.get(key) == value for key, value in ICONS.items()),
                "DMG background or icon view settings changed")
        require(store[app_name]["Iloc"] == (180, 220), "DMG app icon moved")
        require(store["Applications"]["Iloc"] == (480, 220),
                "DMG Applications icon moved")
        alias = Alias.from_bytes(icons["backgroundImageAlias"])
    expected = Alias.from_bytes(Alias.for_file(str(background.resolve())).to_bytes())
    # Do not pin the absolute mount point: another Mac can mount as Whytap 1.
    require(alias.target.posix_path == expected.target.posix_path and
            alias.target.cnid == expected.target.cnid and
            alias.target.creation_date == expected.target.creation_date and
            alias.volume.name == expected.volume.name and
            alias.volume.creation_date == expected.volume.creation_date,
            "DMG background alias does not point inside this volume")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write", "verify", "preflight"))
    parser.add_argument("--volume", type=Path)
    parser.add_argument("--app-name")
    parser.add_argument("--background-source", type=Path, required=True)
    args = parser.parse_args()
    try:
        require(args.background_source.is_file(), "DMG background source is missing")
        if args.action != "preflight":
            require(args.volume is not None and args.app_name is not None,
                    "--volume and --app-name are required")
            action = write_layout if args.action == "write" else verify_layout
            action(args.volume, args.app_name, args.background_source)
    except Exception as error:
        print("ERROR: DMG layout: {}".format(error), file=sys.stderr)
        return 1
    print("  ok: DMG layout {}".format(args.action))
    return 0


if __name__ == "__main__":
    sys.exit(main())
