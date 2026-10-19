#!/usr/bin/env python3
"""Print the UDID of the newest available iPhone simulator."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from typing import Any


def version_from_runtime(runtime: str) -> tuple[int, ...]:
    match = re.search(r"iOS[- ](\d+(?:[-.]\d+)*)$", runtime)
    if not match:
        return ()
    return tuple(int(part) for part in re.split(r"[-.]", match.group(1)))


def main() -> int:
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            check=True,
            capture_output=True,
            text=True,
        )
        payload: dict[str, Any] = json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"Could not read available simulators: {exc}", file=sys.stderr)
        return 1

    candidates: list[tuple[tuple[int, ...], str, str]] = []
    for runtime, devices in payload.get("devices", {}).items():
        version = version_from_runtime(runtime)
        if not version:
            continue
        for device in devices:
            name = str(device.get("name", ""))
            udid = str(device.get("udid", ""))
            if name.startswith("iPhone") and udid and device.get("isAvailable", True):
                candidates.append((version, name, udid))

    if not candidates:
        print("No available iPhone simulator was found.", file=sys.stderr)
        return 1

    # Prefer the newest runtime, then a deterministic device name.
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    version, name, udid = candidates[0]
    print(f"Selected {name} on iOS {'.'.join(map(str, version))}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
