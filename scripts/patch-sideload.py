#!/usr/bin/env python3
"""Align app group / entitlements. Do not force one bundle id onto plugins."""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(os.environ.get("SIDELOAD_SRC", "sing-box-for-apple"))


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        if new.strip() in text:
            print("ALREADY", path)
            return
        raise SystemExit(f"pattern not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("PATCH", path)


def write_entitlements(path: Path) -> None:
    path.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.networking.networkextension</key>
	<array>
		<string>packet-tunnel-provider</string>
	</array>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$(APP_GROUP_IDENTIFIER)</string>
	</array>
</dict>
</plist>
""",
        encoding="utf-8",
    )
    print("WRITE", path)


def main() -> None:
    bundle_id = os.environ.get("SIDELOAD_BUNDLE_ID", "").strip()
    app_group = os.environ.get("SIDELOAD_APP_GROUP", "").strip()
    if not bundle_id or not app_group:
        raise SystemExit("SIDELOAD_BUNDLE_ID and SIDELOAD_APP_GROUP are required")
    print("BUNDLE", bundle_id)
    print("GROUP", app_group)

    file_path = ROOT / "Library" / "Shared" / "FilePath.swift"
    replace_once(
        file_path,
        "    private static let defaultSharedDirectory: URL! = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)\n\n    #if os(iOS)\n        public static let sharedDirectory = defaultSharedDirectory!\n",
        """    private static func resolvedSharedDirectory() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private static let defaultSharedDirectory: URL! = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)

    #if os(iOS)
        public static let sharedDirectory = resolvedSharedDirectory()
""",
    )

    write_entitlements(ROOT / "SFI" / "SFI.entitlements")
    write_entitlements(ROOT / "Extension" / "Extension.entitlements")


if __name__ == "__main__":
    main()
