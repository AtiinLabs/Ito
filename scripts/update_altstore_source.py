#!/usr/bin/env python3
"""Create or update an AltStore/SideStore source for one Ito release channel."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

DEFAULT_BUNDLE_ID = "moe.itoapp.ito"
WEBSITE = "https://github.com/AtiinLabs/Ito"

# AltStore and SideStore reject an install unless the downloaded app's
# CFBundleShortVersionString equals the source "version", so feed versions are
# the app's numeric X.Y.Z. Channel labels belong in the release notes.
APP_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
LABELED_VERSION = re.compile(r"^(\d+\.\d+\.\d+)-")

CHANNEL_METADATA = {
    "stable": {
        "source_name": "Ito",
        "source_identifier": "moe.itoapp.source",
        "source_subtitle": "Stable unsigned releases of Ito",
        "app_name": "Ito",
        "app_subtitle": "Stable release channel",
    },
    "beta": {
        "source_name": "Ito Beta",
        "source_identifier": "moe.itoapp.source.beta",
        "source_subtitle": "Beta and release-candidate builds of Ito",
        "app_name": "Ito Beta",
        "app_subtitle": "Beta and release-candidate channel",
    },
    "nightly": {
        "source_name": "Ito Nightly",
        "source_identifier": "moe.itoapp.source.nightly",
        "source_subtitle": "Automated nightly builds from main",
        "app_name": "Ito Nightly",
        "app_subtitle": "Unstable nightly channel",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--channel", required=True, choices=tuple(CHANNEL_METADATA))
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--version", required=True, help="App CFBundleShortVersionString, X.Y.Z")
    parser.add_argument("--display-version", help="Channel version for release notes, e.g. 1.1.0-beta.1")
    parser.add_argument("--sha256", required=True, help="Hex SHA-256 of the IPA")
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--size", required=True, type=int)
    parser.add_argument("--release-notes", default="")
    parser.add_argument("--max-versions", type=int, default=50)
    return parser.parse_args()


def default_source(source_url: str, source_filename: str, channel: str) -> dict[str, Any]:
    metadata = CHANNEL_METADATA[channel]
    return {
        "name": metadata["source_name"],
        "identifier": metadata["source_identifier"],
        "subtitle": metadata["source_subtitle"],
        "description": (
            "Ito IPAs built without an App Store signing identity. "
            "AltStore and SideStore re-sign downloads with the user's Apple account."
        ),
        "website": WEBSITE,
        "sourceURL": f"{source_url}/{source_filename}",
        "iconURL": f"{source_url}/icon.png",
        "tintColor": "6C5CE7",
        "apps": [],
        "news": [],
    }


def main() -> int:
    args = parse_args()
    if args.max_versions < 1:
        raise SystemExit("--max-versions must be at least 1")

    args.file.parent.mkdir(parents=True, exist_ok=True)
    source_url = args.source_url.rstrip("/")
    source_filename = args.file.name
    metadata = CHANNEL_METADATA[args.channel]

    if args.file.exists():
        try:
            source: dict[str, Any] = json.loads(args.file.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Existing source is invalid JSON: {exc}") from exc
    else:
        source = default_source(source_url, source_filename, args.channel)

    icon_url = f"{source_url}/icon.png"
    source.update(
        {
            "name": metadata["source_name"],
            "identifier": metadata["source_identifier"],
            "subtitle": metadata["source_subtitle"],
            "sourceURL": f"{source_url}/{source_filename}",
            "iconURL": icon_url,
            "website": WEBSITE,
        }
    )
    apps = source.setdefault("apps", [])

    app = next(
        (candidate for candidate in apps if candidate.get("bundleIdentifier") == args.bundle_id),
        None,
    )
    if app is None:
        app = {
            "name": metadata["app_name"],
            "bundleIdentifier": args.bundle_id,
            "developerName": "Ito contributors",
            "subtitle": metadata["app_subtitle"],
            "localizedDescription": (
                "An unsigned Ito build for installation through AltStore, SideStore, "
                "TrollStore-compatible setups, or jailbreak tooling."
            ),
            "iconURL": icon_url,
            "tintColor": "6C5CE7",
            "category": "entertainment",
            "appPermissions": {"entitlements": [], "privacy": {}},
            "versions": [],
        }
        apps.append(app)

    app["name"] = metadata["app_name"]
    app["subtitle"] = metadata["app_subtitle"]
    app["iconURL"] = icon_url

    if not APP_VERSION.match(args.version):
        raise SystemExit(f"--version must be the app's numeric X.Y.Z version; got {args.version!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
        raise SystemExit(f"--sha256 must be 64 lowercase hex characters; got {args.sha256!r}")
    display_version = args.display_version or args.version
    description = f"Ito {display_version} (build {args.build_version})."
    if args.release_notes:
        description = f"{description} {args.release_notes}"

    version_entry = {
        "version": args.version,
        "buildVersion": str(args.build_version),
        "date": args.date,
        "downloadURL": args.download_url,
        "size": args.size,
        "sha256": args.sha256,
        "localizedDescription": description,
        "minOSVersion": "15.4",
    }

    versions = []
    for item in app.setdefault("versions", []):
        # Earlier entries carried the channel label in "version", which no store
        # accepts; the IPAs themselves report the numeric prefix.
        labeled = LABELED_VERSION.match(str(item.get("version", "")))
        if labeled:
            item["version"] = labeled.group(1)
        if (
            str(item.get("version")) == args.version
            and str(item.get("buildVersion")) == str(args.build_version)
        ):
            continue
        versions.append(item)
    versions.insert(0, version_entry)
    app["versions"] = versions[: args.max_versions]

    latest = app["versions"][0]
    for key in ("version", "buildVersion", "date", "downloadURL", "size", "minOSVersion"):
        app[key] = latest[key]
    app["versionDescription"] = latest.get("localizedDescription", "")

    args.file.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
