#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
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
PAGES_DIR="${RUNNER_TEMP}/ito-pages"
RELEASE_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
IPA_SIZE="$(stat -f '%z' "$IPA_PATH")"
IPA_SHA256="$(shasum -a 256 "$IPA_PATH" | cut -d ' ' -f 1)"

# Stable and dev runs can publish concurrently. Each attempt rebuilds the update
# from the current gh-pages head; a rejected push means another channel landed
# first, so start over from its result.
publish_once() {
  rm -rf "$PAGES_DIR"
  if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git clone --depth=1 --branch gh-pages "https://github.com/${GITHUB_REPOSITORY}.git" "$PAGES_DIR"
  else
    mkdir -p "$PAGES_DIR"
    git -C "$PAGES_DIR" init
    git -C "$PAGES_DIR" checkout --orphan gh-pages
    git -C "$PAGES_DIR" remote add origin "https://github.com/${GITHUB_REPOSITORY}.git"
  fi

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
  python3 scripts/render_pages_index.py --dir "$PAGES_DIR" --source-url "$SOURCE_URL"
  touch "$PAGES_DIR/.nojekyll"

  git -C "$PAGES_DIR" config user.name "github-actions[bot]"
  git -C "$PAGES_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git -C "$PAGES_DIR" add "$SOURCE_FILE" icon.png index.html .nojekyll
  if git -C "$PAGES_DIR" diff --cached --quiet; then
    return 0
  fi
  git -C "$PAGES_DIR" commit -m "chore: publish Ito ${CHANNEL} ${VERSION}"
  git -C "$PAGES_DIR" remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git -C "$PAGES_DIR" push origin HEAD:gh-pages || return "$PUSH_REJECTED"
}

PUSH_REJECTED=75
for attempt in 1 2 3 4 5; do
  # Run the attempt in a subshell outside any condition, with errexit re-enabled,
  # so any failure inside publish_once stops it.
  set +e
  (set -e; publish_once)
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    exit 0
  fi
  if [[ "$status" -ne "$PUSH_REJECTED" ]]; then
    exit "$status"
  fi
  echo "gh-pages moved during publication (attempt $attempt); retrying from the new head." >&2
done
echo "Could not publish ${SOURCE_FILE} after 5 attempts." >&2
exit 1
