#!/usr/bin/env bash
# Runs the SwiftLint release pinned below, the same version as the Xcode build
# plugin in Package.resolved, so the hook, CI, and Xcode report the same rules.
# Arguments are passed to swiftlint, e.g. `scripts/swiftlint.sh lint --strict`.
set -euo pipefail

VERSION="0.63.3"
MACOS_SHA256="fb045e85e7cb3374f42a4840b6b85a0106302afa69035c0c6f29af4a44c810b6"
LINUX_AMD64_SHA256="26db741d43f2f2dc26c0cf16911100a3e186c3d1dbb59e55ad3ac87b0de4538f"
LINUX_ARM64_SHA256="d5efcbed5ec1ca9eb7f833dfdd9f80f56289750b72582c7c1686b4528e182454"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED="${ROOT}/Ito.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

plugin_version="$(
  python3 - "$RESOLVED" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == "swiftlintplugins"))
PY
)"
if [[ "$plugin_version" != "$VERSION" ]]; then
  echo "scripts/swiftlint.sh pins SwiftLint ${VERSION}, but Package.resolved uses SwiftLintPlugins ${plugin_version}." >&2
  echo "Update VERSION and the checksums in scripts/swiftlint.sh to match." >&2
  exit 1
fi

# The Linux archives also ship a dynamically linked binary that needs a Swift runtime.
case "$(uname -s)/$(uname -m)" in
  Darwin/*) asset="portable_swiftlint.zip"; member="swiftlint"; sha256="$MACOS_SHA256" ;;
  Linux/x86_64) asset="swiftlint_linux_amd64.zip"; member="swiftlint-static"; sha256="$LINUX_AMD64_SHA256" ;;
  Linux/aarch64 | Linux/arm64) asset="swiftlint_linux_arm64.zip"; member="swiftlint-static"; sha256="$LINUX_ARM64_SHA256" ;;
  *) echo "Unsupported platform: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/ito/swiftlint/${VERSION}/${asset%.zip}"
binary="${cache_dir}/swiftlint"

if [[ ! -x "$binary" ]]; then
  mkdir -p "$cache_dir"
  archive="$(mktemp "${cache_dir}/download.XXXXXX")"
  extracted="$(mktemp "${cache_dir}/swiftlint.XXXXXX")"
  trap 'rm -f "$archive" "$extracted"' EXIT
  curl -fsSL --retry 3 -o "$archive" \
    "https://github.com/realm/SwiftLint/releases/download/${VERSION}/${asset}"
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  fi
  if [[ "$actual" != "$sha256" ]]; then
    echo "Checksum mismatch for ${asset}: expected ${sha256}, got ${actual}" >&2
    exit 1
  fi
  unzip -p "$archive" "$member" > "$extracted"
  chmod +x "$extracted"
  mv -f "$extracted" "$binary"
  rm -f "$archive"
  trap - EXIT
fi

cd "$ROOT"
exec "$binary" "$@"
