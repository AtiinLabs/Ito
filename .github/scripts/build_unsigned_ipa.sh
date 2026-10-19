#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-Ito.xcodeproj}"
SCHEME="${SCHEME:-Ito}"
CONFIGURATION="${CONFIGURATION:-Release}"
MARKETING_VERSION="${MARKETING_VERSION:-${VERSION:-0.0.0}}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-${VERSION:-$MARKETING_VERSION}}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
CHANNEL="${CHANNEL:-stable}"
OUTPUT_DIR="${1:-build/release}"
ARCHIVE_PATH="${OUTPUT_DIR}/Ito.xcarchive"
STAGING_DIR="${OUTPUT_DIR}/staging"
IPA_NAME="Ito-${ARTIFACT_VERSION}-unsigned.ipa"
IPA_PATH="${OUTPUT_DIR}/${IPA_NAME}"
CHECKSUM_PATH="${IPA_PATH}.sha256"
# TrollStore registers the .tipa extension; the file is the same unsigned IPA,
# which TrollStore fake-signs on install.
TIPA_NAME="${IPA_NAME%.ipa}.tipa"
TIPA_PATH="${OUTPUT_DIR}/${TIPA_NAME}"
TIPA_CHECKSUM_PATH="${TIPA_PATH}.sha256"

if [[ ! -f "$PROJECT/project.pbxproj" ]]; then
  echo "Run this script from the Ito repository root." >&2
  exit 1
fi

# CFBundleShortVersionString must remain numeric. Channel labels belong in the
# artifact/source version, not in MARKETING_VERSION.
if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "MARKETING_VERSION must be numeric X.Y.Z; got: $MARKETING_VERSION" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo "BUILD_NUMBER must contain only numbers and up to two dots; got: $BUILD_NUMBER" >&2
  exit 1
fi

if [[ ! "$ARTIFACT_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "ARTIFACT_VERSION contains unsafe filename characters: $ARTIFACT_VERSION" >&2
  exit 1
fi

if [[ ! "$CHANNEL" =~ ^(stable|dev)$ ]]; then
  echo "CHANNEL must be stable or dev; got: $CHANNEL" >&2
  exit 1
fi

rm -rf "$ARCHIVE_PATH" "$STAGING_DIR" "$IPA_PATH" "$CHECKSUM_PATH" "$TIPA_PATH" "$TIPA_CHECKSUM_PATH"
mkdir -p "$OUTPUT_DIR" "$STAGING_DIR/Payload"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  EXPANDED_CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  | tee "${OUTPUT_DIR}/archive.log"

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Ito.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive did not contain $APP_PATH" >&2
  exit 1
fi

cp -R "$APP_PATH" "$STAGING_DIR/Payload/Ito.app"
PACKAGED_APP="$STAGING_DIR/Payload/Ito.app"

# Ensure the public artifact contains neither a provisioning profile nor stale
# signatures. Alternative stores can then apply the user's own signature.
find "$PACKAGED_APP" -name embedded.mobileprovision -delete
find "$PACKAGED_APP" -name _CodeSignature -type d -prune -exec rm -rf {} +
while IFS= read -r -d '' item; do
  codesign --remove-signature "$item" >/dev/null 2>&1 || true
done < <(find "$PACKAGED_APP" \
  \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' \) \
     -o -type f -name '*.dylib' \) -print0)

(
  cd "$STAGING_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "../${IPA_NAME}"
)

if ! /usr/bin/unzip -Z1 "$IPA_PATH" | grep -q '^Payload/Ito.app/Info.plist$'; then
  echo "IPA validation failed: Payload/Ito.app/Info.plist is missing." >&2
  exit 1
fi

cp "$IPA_PATH" "$TIPA_PATH"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$IPA_NAME" > "${IPA_NAME}.sha256"
  shasum -a 256 "$TIPA_NAME" > "${TIPA_NAME}.sha256"
)

printf 'Created %s and %s\n' "$IPA_PATH" "$TIPA_PATH"
printf 'Channel: %s\n' "$CHANNEL"
printf 'App version: %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
printf 'Artifact version: %s\n' "$ARTIFACT_VERSION"
printf 'SHA-256: %s\n' "$(cut -d ' ' -f 1 "$CHECKSUM_PATH")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "ipa_path=$IPA_PATH"
    echo "ipa_name=$IPA_NAME"
    echo "checksum_path=$CHECKSUM_PATH"
    echo "tipa_path=$TIPA_PATH"
    echo "tipa_name=$TIPA_NAME"
    echo "tipa_checksum_path=$TIPA_CHECKSUM_PATH"
    echo "marketing_version=$MARKETING_VERSION"
    echo "artifact_version=$ARTIFACT_VERSION"
    echo "channel=$CHANNEL"
  } >> "$GITHUB_OUTPUT"
fi
