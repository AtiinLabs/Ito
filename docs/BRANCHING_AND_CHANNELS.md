# Branching and binary channels

## Development and release graph

```text
feat/* ─────┐
fix/* ──────┤
            ▼
main ──●────●────●────────●────────────► next version
       │         │        │
       │         │        └─ scheduled nightly
       │         │
       │         └─ release/1.3.0 ─●─●─ v1.3.0-beta.1
       │                            └─── v1.3.0-rc.1
       │                                  │
       │                       merge back ▼
       └─────────────────────────────────●─ v1.3.0 stable
                                           │
                                           └─ hotfix/1.3.1 ─●─ merge ─ v1.3.1
```

## Branch responsibilities

### `main`

`main` is the integration branch for the next version and should remain buildable. Normal work reaches it through short-lived pull-request branches.

### `release/X.Y.Z`

Cut this branch when version `X.Y.Z` is feature-complete. Permit only stabilization changes:

- bug fixes;
- version/build metadata;
- localization corrections;
- release notes;
- distribution and App Store metadata;
- release-specific migrations.

Create beta and RC tags from this branch. Merge all final changes back into `main`, then create the stable tag from the merged commit.

### `hotfix/X.Y.Z`

Cut this from the last stable tag for an urgent production fix. After validation, merge it into `main` and any still-maintained release branch, then tag the merged stable commit.

## Tag rules

Accepted public release tags are:

```text
v1.3.0-beta.1
v1.3.0-rc.1
v1.3.0
```

Do not move or reuse `v*` tags. Configure a GitHub tag ruleset that blocks updates and deletion for `v*`.

Nightly tags use an automated form such as:

```text
nightly-20260724-318
```

They are intentionally temporary; the nightly workflow retains the newest 14 and removes older nightly releases and tags.

## Binary channels

| Channel | Trigger | GitHub release | Source file | Intended audience |
|---|---|---|---|---|
| Nightly | Daily schedule or manual run from `main` | Prerelease | `apps-nightly.json` | Early testers |
| Beta/RC | `vX.Y.Z-beta.N` or `vX.Y.Z-rc.N` | Prerelease | `apps-beta.json` | Release testers |
| Stable | `vX.Y.Z` | Full release | `apps.json` | General users |

The app's `MARKETING_VERSION`, set in `Configuration/Version.xcconfig`, stays numeric (`X.Y.Z`) while the complete channel version is used in artifact names and source metadata. This avoids invalid iOS bundle-version strings such as `1.3.0-beta.1`. Build numbers are the commit count of the built commit in every channel.

## Current installation behavior

All channels currently use `moe.itoapp.ito`. A nightly, beta, or stable installation therefore replaces any other installed Ito channel.

To support side-by-side installs later, introduce Xcode configurations or schemes with separate values such as:

```text
Stable:  moe.itoapp.ito
Beta:    moe.itoapp.ito.beta
Nightly: moe.itoapp.ito.nightly
```

That change must also review App Groups, keychain groups, URL schemes, extensions, associated domains, and other entitlements before the bundle identifier is overridden in CI.
