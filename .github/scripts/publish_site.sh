#!/usr/bin/env bash
# Publish site/ to the root of gh-pages and re-render install/ from the feeds
# already there. The feeds are owned by publish_altstore_source.sh.
set -euo pipefail

SCRIPTS="$(dirname "$0")"
# shellcheck source=.github/scripts/gh_pages.sh
source "${SCRIPTS}/gh_pages.sh"

update_site() {
  local owner
  owner="$(printf '%s' "${GITHUB_REPOSITORY%%/*}" | tr '[:upper:]' '[:lower:]')"
  cp site/index.html "$PAGES_DIR/index.html"
  python3 "${SCRIPTS}/render_install_page.py" --dir "$PAGES_DIR" --source-url "https://${owner}.github.io/${GITHUB_REPOSITORY#*/}"
  git -C "$PAGES_DIR" add index.html install/index.html
}

publish_gh_pages "chore: publish site from $(git rev-parse --short HEAD)" update_site
