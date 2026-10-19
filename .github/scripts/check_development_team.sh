#!/usr/bin/env bash
# Fails if an Xcode project or xcconfig file sets a development team. Team IDs
# belong to a personal Apple account: set one locally in Xcode and leave the
# change uncommitted. CI builds unsigned and needs none.
#
# Usage: check_development_team.sh [--staged] [file ...]
#   --staged  check the staged (index) content instead of the working tree
#   no files  check every tracked .pbxproj and .xcconfig file
set -euo pipefail

staged=false
if [[ "${1:-}" == "--staged" ]]; then
  staged=true
  shift
fi

if [[ $# -eq 0 ]]; then
  # shellcheck disable=SC2046 # tracked project paths contain no whitespace
  set -- $(git ls-files '*.pbxproj' '*.xcconfig')
fi

pattern='(DEVELOPMENT_TEAM|DevelopmentTeam)[[:space:]]*=[[:space:]]*"?[A-Za-z0-9]+"?[[:space:]]*;'
found=false
for file in "$@"; do
  if [[ "$staged" == true ]]; then
    content="$(git show ":$file")"
  else
    content="$(cat "$file")"
  fi
  if matches="$(grep -nE "$pattern" <<<"$content")"; then
    found=true
    while IFS= read -r match; do
      echo "${file}:${match%%:*}: ${match#*:}" | sed -E 's/[[:space:]]+/ /g' >&2
    done <<<"$matches"
  fi
done

if [[ "$found" == true ]]; then
  echo "A development team ID is set. Remove it from the commit; keep it only in your local checkout." >&2
  exit 1
fi
