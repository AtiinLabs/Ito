# Unsigned release process

Ito currently distributes unsigned device IPAs. AltStore and SideStore can re-sign them with the user's Apple account; TrollStore and jailbreak installation depend on the target device and environment. App Store/TestFlight signing remains a separate future workflow.

## One-time repository setup

1. Copy this starter kit into the Ito repository.
2. In **Settings → Pages**, publish from the `gh-pages` branch and `/ (root)`.
3. Protect `main`, require pull requests, and require the `Build and unit test` check.
4. Add a tag ruleset for `v*` that blocks tag updates and deletion.
5. Keep `.github/ito-runner.ref` pinned to a reviewed companion-repository commit.
6. Ensure the repository's Actions token has `contents: write` for release workflows.

## Dev channel

The dev workflow runs on every push to `main` and can also be started manually. A newer push to `main` cancels an in-progress dev run.

It publishes:

```text
Ito-X.Y.Z-dev.BUILD-unsigned.ipa
Ito-X.Y.Z-dev.BUILD-unsigned.ipa.sha256
```

For example `Ito-1.3.0-dev.124-unsigned.ipa`. It creates a GitHub prerelease tagged `dev-BUILD` and titled `X.Y.Z-dev.BUILD`, updates `apps-dev.json`, and keeps the newest 14 dev releases, deleting older dev releases and tags. Dev builds may be unstable.

## App version and build number

`Configuration/Version.xcconfig` is the only place the version is set:

- `MARKETING_VERSION` is the numeric `X.Y.Z` version of the next stable release. It becomes `CFBundleShortVersionString`, is shown in Settings, and is compared with each plugin's `min_app_version`.
- The build number (`CFBundleVersion`) is the commit count of the built commit, `git rev-list --count HEAD`. Dev and release workflows set it, so the same commit has the same build number in both channels and builds increase along `main`. Local builds use 1.

Release tags must match the file: `v1.3.0` requires `MARKETING_VERSION = 1.3.0` at the tagged commit, or the release workflow stops. Tags with a suffix after the version are rejected.

`main` declares the version its contents would be released as. After tagging `v1.3.0`, bump `main` to the patch version `1.3.1` so dev builds stop claiming the released version. The first pull request after that which adds a feature also bumps the minor version (`1.4.0`); breaking changes bump the major version. The version on `main` only moves forward.

## Publish a stable version

1. Confirm the latest `main` commit has a passing CI run.
2. Confirm `Configuration/Version.xcconfig` on that commit declares the version to release (for example `1.3.0`).
3. Tag the commit and push the tag:

```bash
git switch main
git pull --ff-only
git tag -a v1.3.0 -m "Ito 1.3.0"
git push origin v1.3.0
```

The tagged commit must be contained in `main`. The workflow tests it, builds an unsigned IPA, creates a full GitHub Release, and updates `apps.json`.

4. Open a pull request that bumps `MARKETING_VERSION` on `main` to the patch version (for example `1.3.1`).

## Urgent fix after a release

There is no stabilization branch, so a stable release ships everything already on `main`, and an urgent fix is the next release of `main`:

1. Merge the fix into `main` through a reviewed pull request.
2. Release the version `main` declares. If only fixes landed since `v1.3.0`, that is `1.3.1`; if a feature landed, it is `1.4.0` and the fix ships with it.
3. Tag and push, for example:

```bash
git switch main
git pull --ff-only
git tag -a v1.3.1 -m "Ito 1.3.1"
git push origin v1.3.1
```

## AltStore and SideStore sources

After the first publication in each channel:

```text
Stable: https://atiinlabs.github.io/Ito/apps.json
Dev:    https://atiinlabs.github.io/Ito/apps-dev.json
```

Both feeds describe the same bundle identifier. Installing one channel replaces the other.

Each source entry's `version` is the app's numeric version and `buildVersion` its build number, matching the IPA's Info.plist; AltStore and SideStore refuse an install when they differ. The channel display version (for example `1.3.0-dev.124`) goes in the entry's release notes. Every entry also carries the IPA's `sha256`, which both stores verify after downloading.

GitHub Pages must deploy from the `gh-pages` branch (**Settings → Pages → Deploy from a branch**); otherwise the feeds are committed but never served.

## What each publication does

1. validates the tag or dev build metadata;
2. checks out Ito and the pinned `ito-runner` sibling;
3. resolves Swift packages;
4. runs unit tests on an available iPhone simulator;
5. archives a generic iOS device build with signing disabled;
6. removes stale signatures and provisioning profiles;
7. packages `Payload/Ito.app` as an IPA;
8. creates a SHA-256 checksum;
9. publishes a GitHub release or prerelease;
10. updates the channel-specific AltStore/SideStore source on `gh-pages`.

## Future App Store/TestFlight path

Keep signed distribution in a separate workflow. When an Apple Developer Program account becomes available:

- create an App Store archive from the same stable tag;
- install distribution certificates and provisioning profiles from encrypted secrets;
- export and upload the signed build;
- use a TestFlight lane from `main` for pre-release testing;
- keep the unsigned IPA publication available for alternative distribution when desired.

Do not add unavailable signing credentials to the unsigned workflows.

## Rollback

For a stable release, mark the release unavailable or publish a newer patch version; do not move or reuse a `v*` tag. Remove an unsafe version from the matching source JSON on `gh-pages` if necessary.

Dev releases are temporary and automatically pruned.
