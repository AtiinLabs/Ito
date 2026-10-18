#!/usr/bin/env bash
# Publish site/ to the root of gh-pages and re-render install/ from the feeds
# already there. The feeds are owned by publish_altstore_source.sh.
set -euo pipefail

# shellcheck source=scripts/gh_pages.sh
source "$(dirname "$0")/gh_pages.sh"

update_site() {
  local owner
  owner="$(printf '%s' "${GITHUB_REPOSITORY%%/*}" | tr '[:upper:]' '[:lower:]')"
  cp site/index.html "$PAGES_DIR/index.html"
  python3 scripts/render_install_page.py --dir "$PAGES_DIR" --source-url "https://${owner}.github.io/${GITHUB_REPOSITORY#*/}"
  git -C "$PAGES_DIR" add index.html install/index.html
}

publish_gh_pages "chore: publish site from $(git rev-parse --short HEAD)" update_site
