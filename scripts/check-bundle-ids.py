#!/usr/bin/env python3
"""Fail the build if the app, plugins, or frameworks share a bundle id."""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path


def plist_id(path: Path) -> str | None:
    if not path.is_file():
        return None
    data = plistlib.loads(path.read_bytes())
    value = data.get("CFBundleIdentifier")
    return str(value) if value else None


def main() -> None:
    app = Path(sys.argv[1])
    files = [app / "Info.plist"]
    plugins = app / "PlugIns"
    if plugins.is_dir():
        files.extend(sorted(plugins.glob("*.appex/Info.plist")))
    frameworks = app / "Frameworks"
    if frameworks.is_dir():
        files.extend(sorted(frameworks.glob("*.framework/Info.plist")))

    seen: dict[str, str] = {}
    for path in files:
        bundle_id = plist_id(path)
        if not bundle_id:
            continue
        rel = str(path.relative_to(app))
        print("ID", bundle_id, rel)
        if bundle_id in seen:
            raise SystemExit(f"duplicate bundle id {bundle_id}: {seen[bundle_id]} and {rel}")
        seen[bundle_id] = rel

    app_id = plist_id(app / "Info.plist")
    ext_id = plist_id(app / "PlugIns" / "Extension.appex" / "Info.plist")
    if not app_id or not ext_id:
        raise SystemExit("missing app or extension bundle id")
    if app_id == ext_id:
        raise SystemExit("app and extension must not share a bundle id")
    print("OK", app_id, ext_id)


if __name__ == "__main__":
    main()
