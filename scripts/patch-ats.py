#!/usr/bin/env python3
"""Force HTTP allow in the built app Info.plist. GENERATE_INFOPLIST_FILE can drop the source key."""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: patch-ats.py <App.app>")
    app = Path(sys.argv[1])
    info = app / "Info.plist"
    with info.open("rb") as fh:
        plist = plistlib.load(fh)
    transport = plist.get("NSAppTransportSecurity")
    if not isinstance(transport, dict):
        transport = {}
    transport["NSAllowsArbitraryLoads"] = True
    transport["NSAllowsLocalNetworking"] = True
    plist["NSAppTransportSecurity"] = transport
    with info.open("wb") as fh:
        plistlib.dump(plist, fh)
    print("ATS", info, "NSAllowsArbitraryLoads=true")


if __name__ == "__main__":
    main()
