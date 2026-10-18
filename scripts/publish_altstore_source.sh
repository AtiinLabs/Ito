#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/gh_pages.sh
source "$(dirname "$0")/gh_pages.sh"

: "${TAG:?TAG is required}"
: "${CHANNEL:?CHANNEL is required}"
: "${VERSION:?VERSION is required}"
: "${APP_VERSION:?APP_VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
: "${IPA_PATH:?IPA_PATH is required}"
: "${IPA_NAME:?IPA_NAME is required}"
: "${BUNDLE_ID:?BUNDLE_ID is required}"

RELEASE_NOTES="${RELEASE_NOTES:-Unsigned Ito ${VERSION} build.}"
MAX_VERSIONS="${MAX_VERSIONS:-50}"

case "$CHANNEL" in
  stable) SOURCE_FILE="apps.json" ;;
  dev) SOURCE_FILE="apps-dev.json" ;;
  *) echo "Unsupported channel: $CHANNEL" >&2; exit 1 ;;
esac

# GitHub Pages hostnames are lowercase; the stores keep sourceURL as the source's identity.
OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')"
REPO="${GITHUB_REPOSITORY#*/}"
SOURCE_URL="https://${OWNER}.github.io/${REPO}"
DOWNLOAD_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/${IPA_NAME}"
RELEASE_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
IPA_SIZE="$(stat -f '%z' "$IPA_PATH")"
IPA_SHA256="$(shasum -a 256 "$IPA_PATH" | cut -d ' ' -f 1)"

update_source() {
  python3 scripts/update_altstore_source.py \
    --file "$PAGES_DIR/$SOURCE_FILE" \
    --source-url "$SOURCE_URL" \
    --channel "$CHANNEL" \
    --bundle-id "$BUNDLE_ID" \
    --version "$APP_VERSION" \
    --display-version "$VERSION" \
    --sha256 "$IPA_SHA256" \
    --build-version "$BUILD_NUMBER" \
    --date "$RELEASE_DATE" \
    --download-url "$DOWNLOAD_URL" \
    --size "$IPA_SIZE" \
    --release-notes "$RELEASE_NOTES" \
    --max-versions "$MAX_VERSIONS"

  cp Ito/Assets.xcassets/AppIcon.appiconset/app.png "$PAGES_DIR/icon.png"
  python3 scripts/render_install_page.py --dir "$PAGES_DIR" --source-url "$SOURCE_URL"
  git -C "$PAGES_DIR" add "$SOURCE_FILE" icon.png install/index.html
}

publish_gh_pages "chore: publish Ito ${CHANNEL} ${VERSION}" update_source
