#!/usr/bin/env python3
"""Render the gh-pages index from the channel sources present in a directory."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path
from urllib.parse import quote

CHANNELS = (
    ("Stable", "apps.json"),
    ("Dev", "apps-dev.json"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True, type=Path)
    parser.add_argument("--source-url", required=True)
    return parser.parse_args()


def channel_section(title: str, source_url: str, source: dict) -> str:
    latest = source["apps"][0]["versions"][0]
    ipa_url = latest["downloadURL"]
    if not ipa_url.endswith(".ipa"):
        raise SystemExit(f"{title} downloadURL does not end in .ipa: {ipa_url}")
    # build_unsigned_ipa.sh publishes the .tipa next to the IPA under the same name.
    tipa_url = ipa_url[: -len(".ipa")] + ".tipa"
    links = (
        # Feather takes the raw URL after /source/ and requires https://.
        (f"feather://source/{source_url}", "Add source to Feather"),
        (f"apple-magnifier://install?url={quote(tipa_url, safe='')}", "Install with TrollStore"),
        (tipa_url, "Download .tipa"),
        (ipa_url, "Download .ipa"),
    )
    items = "\n".join(
        f'  <li><a href="{html.escape(href)}">{html.escape(label)}</a></li>' for href, label in links
    )
    version = f"{latest['version']} ({latest['buildVersion']})"
    return (
        f"<h2>{html.escape(title)} {html.escape(version)}</h2>\n"
        f"<p>AltStore, SideStore, and Feather source: <code>{html.escape(source_url)}</code></p>\n"
        f"<ul>\n{items}\n</ul>"
    )


def main() -> int:
    args = parse_args()
    base_url = args.source_url.rstrip("/")
    sections = []
    for title, filename in CHANNELS:
        path = args.dir / filename
        if path.exists():
            source = json.loads(path.read_text(encoding="utf-8"))
            sections.append(channel_section(title, f"{base_url}/{filename}", source))

    body = "\n".join(sections)
    page = f"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ito</title>
<h1>Ito</h1>
{body}
<p>Both channels use the same bundle identifier, so installing one replaces the other. TrollStore signs the unsigned app with ldid on install; install ldid from TrollStore settings first.</p>
"""
    (args.dir / "index.html").write_text(page, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
