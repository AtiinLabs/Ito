#!/usr/bin/env python3
"""Render install/index.html on gh-pages from the channel sources present."""

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

STYLE = """
:root { color-scheme: dark; }
body { margin: 0 auto; max-width: 640px; padding: 40px 22px 64px; background: #000; color: #f5f5f7;
  font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
a { color: #9de3c6; }
h1 { margin: 24px 0 8px; font-size: 32px; letter-spacing: -0.02em; }
h2 { margin: 40px 0 6px; padding-top: 20px; border-top: 1px solid rgba(255, 255, 255, 0.12); font-size: 21px; }
p, li { color: rgba(245, 245, 247, 0.72); }
ul { padding-left: 20px; }
li { margin: 6px 0; }
code { font: 13px ui-monospace, "SF Mono", Menlo, monospace; color: #f5f5f7; overflow-wrap: anywhere; }
""".strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True, type=Path, help="gh-pages checkout holding the sources")
    parser.add_argument("--source-url", required=True, help="public base URL of the gh-pages site")
    return parser.parse_args()


def channel_section(title: str, source_url: str, source: dict) -> str:
    latest = source["apps"][0]["versions"][0]
    ipa_url = latest["downloadURL"]
    if not ipa_url.endswith(".ipa"):
        raise SystemExit(f"{title} downloadURL does not end in .ipa: {ipa_url}")
    # build_unsigned_ipa.sh publishes the .tipa next to the IPA under the same name.
    tipa_url = ipa_url[: -len(".ipa")] + ".tipa"
    encoded_source = quote(source_url, safe="")
    links = (
        (f"altstore://source?url={encoded_source}", "Add source to AltStore"),
        (f"sidestore://source?url={encoded_source}", "Add source to SideStore"),
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
        f"<p>Source: <code>{html.escape(source_url)}</code></p>\n"
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
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ito builds</title>
<style>
{STYLE}
</style>
<p><a href="../">← Ito</a></p>
<h1>Builds</h1>
<p>Stable is the latest release. Dev is built from every change to <code>main</code>.</p>
{body}
<p>Both channels use the same bundle identifier, so installing one replaces the other. TrollStore signs the unsigned app with ldid on install; install ldid from TrollStore settings first.</p>
</html>
"""
    out = args.dir / "install" / "index.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text(page, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
