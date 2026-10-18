# Unsigned release process

Ito currently distributes unsigned device IPAs. AltStore and SideStore can re-sign them with the user's Apple account; TrollStore and jailbreak installation depend on the target device and environment. App Store/TestFlight signing remains a separate future workflow.

## One-time repository setup

1. Copy this starter kit into the Ito repository.
2. In **Settings → Pages**, publish from the `gh-pages` branch and `/ (root)`.
3. Protect `main` and require the `Build and unit test` check.
4. Protect `release/*` and `hotfix/*` from force-pushes and deletion; require CI before merging.
5. Add a tag ruleset for `v*` that blocks tag updates and deletion.
6. Keep `.github/ito-runner.ref` pinned to a reviewed companion-repository commit.
7. Ensure the repository's Actions token has `contents: write` for release workflows.

## Nightly channel

The nightly workflow runs daily from current `main` and can also be started manually.

It publishes:

```text
Ito-X.Y.Z-nightly.YYYYMMDD.RUN-unsigned.ipa
Ito-X.Y.Z-nightly.YYYYMMDD.RUN-unsigned.ipa.sha256
```

It creates a GitHub prerelease, updates `apps-nightly.json`, and keeps the newest 14 nightly releases. Nightly builds are not release candidates and may be unstable.

## App version and build number

`Configuration/Version.xcconfig` is the only place the version is set:

- `MARKETING_VERSION` is the numeric `X.Y.Z` version under development. It becomes `CFBundleShortVersionString`, is shown in Settings, and is compared with each plugin's `min_app_version`.
- The build number (`CFBundleVersion`) is the commit count of the built commit, `git rev-list --count HEAD`. Nightly and release workflows set it, so the same commit has the same build number in every channel and builds increase along `main`. Local builds use 1.

Release tags must match the file: `v1.3.0`, `v1.3.0-beta.1`, and `v1.3.0-rc.1` all require `MARKETING_VERSION = 1.3.0` at the tagged commit, or the release workflow stops.

When `main` starts the next version, bump `MARKETING_VERSION` there in a pull request.

## Prepare a version

```bash
git switch main
git pull --ff-only
git switch -c release/1.3.0
git push -u origin release/1.3.0
```

`main` already declares `1.3.0` in `Configuration/Version.xcconfig` when the branch is cut. Only stabilization work should enter `release/1.3.0`. New features continue on `main`; bump `main` to the next version (for example `1.4.0`) after cutting the branch.

## Publish beta and RC builds

Create explicit prerelease tags from the release branch:

```bash
git switch release/1.3.0
git pull --ff-only
git tag -a v1.3.0-beta.1 -m "Ito 1.3.0 beta 1"
git push origin v1.3.0-beta.1
```

Later candidates use:

```text
v1.3.0-beta.2
v1.3.0-rc.1
v1.3.0-rc.2
```

The workflow tests the tagged commit, builds an unsigned IPA, creates a GitHub prerelease, and updates `apps-beta.json`.

## Publish a stable version

Merge the completed release branch back into `main` first. Do not tag an unmerged release-branch-only commit as stable.

```bash
git switch main
git pull --ff-only
# Merge release/1.3.0 through a reviewed pull request.
git tag -a v1.3.0 -m "Ito 1.3.0"
git push origin v1.3.0
```

Stable tags must point to a commit contained in `main`. The workflow creates a full GitHub Release and updates `apps.json`.

After release, delete `release/1.3.0` unless it remains an intentionally maintained release line.

## Hotfix

For an urgent fix to `v1.3.0`:

```bash
git switch --detach v1.3.0
git switch -c hotfix/1.3.1
# Commit and test the fix, then merge through a pull request into main.
git switch main
git pull --ff-only
git tag -a v1.3.1 -m "Ito 1.3.1"
git push origin v1.3.1
```

Also apply the fix to any still-maintained release branch that needs it.

## AltStore and SideStore sources

After the first publication in each channel:

```text
Stable: https://itoapp.github.io/Ito/apps.json
Beta:   https://itoapp.github.io/Ito/apps-beta.json
Nightly:https://itoapp.github.io/Ito/apps-nightly.json
```

All three feeds currently describe the same bundle identifier. Installing one channel replaces another.

## What each publication does

1. validates the tag or nightly metadata;
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
- use beta/RC tags or release-branch commits for TestFlight;
- keep the unsigned IPA publication available for alternative distribution when desired.

Do not add unavailable signing credentials to the unsigned workflows.

## Rollback

For beta or stable releases, mark the release unavailable or publish a newer patch; do not move or reuse a `v*` tag. Remove an unsafe version from the matching source JSON on `gh-pages` if necessary.

Nightly releases are temporary and automatically pruned.
