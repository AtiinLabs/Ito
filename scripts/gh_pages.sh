# shellcheck shell=bash
#
# Shared gh-pages publication, sourced by the publish_*.sh scripts.
#
# publish_gh_pages MESSAGE UPDATE_FUNCTION
#   Clones the current gh-pages head into $PAGES_DIR, runs UPDATE_FUNCTION to
#   change and stage files there, and pushes a commit if anything changed.
#   Feed and site publications run concurrently, so a rejected push means
#   another publisher landed first; the update is then redone on its result.
#
# Requires GH_TOKEN, GITHUB_REPOSITORY and RUNNER_TEMP.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

PAGES_DIR="${RUNNER_TEMP}/ito-pages"
GH_PAGES_PUSH_REJECTED=75

gh_pages_attempt() {
  local message="$1" update="$2"
  local remote="https://github.com/${GITHUB_REPOSITORY}.git"

  rm -rf "$PAGES_DIR"
  if git ls-remote --exit-code --heads "$remote" gh-pages >/dev/null 2>&1; then
    git clone --depth=1 --branch gh-pages "$remote" "$PAGES_DIR"
  else
    mkdir -p "$PAGES_DIR"
    git -C "$PAGES_DIR" init
    git -C "$PAGES_DIR" checkout --orphan gh-pages
    git -C "$PAGES_DIR" remote add origin "$remote"
  fi

  "$update"
  touch "$PAGES_DIR/.nojekyll"
  git -C "$PAGES_DIR" add .nojekyll

  git -C "$PAGES_DIR" config user.name "github-actions[bot]"
  git -C "$PAGES_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  if git -C "$PAGES_DIR" diff --cached --quiet; then
    echo "gh-pages already up to date."
    return 0
  fi
  git -C "$PAGES_DIR" commit -m "$message"
  git -C "$PAGES_DIR" remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git -C "$PAGES_DIR" push origin HEAD:gh-pages || return "$GH_PAGES_PUSH_REJECTED"
}

publish_gh_pages() {
  local message="$1" update="$2" attempt status
  for attempt in 1 2 3 4 5; do
    # Run the attempt in a subshell outside any condition, with errexit
    # re-enabled, so any failure inside it stops the attempt.
    set +e
    (set -e; gh_pages_attempt "$message" "$update")
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
      return 0
    fi
    if [[ "$status" -ne "$GH_PAGES_PUSH_REJECTED" ]]; then
      return "$status"
    fi
    echo "gh-pages moved during publication (attempt $attempt); retrying from the new head." >&2
  done
  echo "Could not publish to gh-pages after 5 attempts." >&2
  return 1
}
