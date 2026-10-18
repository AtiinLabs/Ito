# Branching and binary channels

## Development and release graph

```text
feat/* ─────┐
fix/* ──────┤  reviewed PR, squash merge
            ▼
main ──●────●────●────────●────────────► next version
       │    │    │        │
       │    │    │        └─ v1.3.0 (stable tag)
       │    │    └─ dev build on every push
       │    └─ dev build on every push
       └─ dev build on every push
```

## Branch responsibilities

`main` is the only long-lived branch (besides the generated `gh-pages`). It declares the next stable version in `Configuration/Version.xcconfig`, should remain buildable, and receives all work through short-lived pull-request branches merged with squash. There are no release or hotfix branches; a stable release is a tag on `main`.

A stable release ships everything already on `main`. There is no stabilization branch, so an urgent fix after a release is merged into `main` and released as the version `main` declares: a patch if only fixes landed since the last release, otherwise the minor version that already includes new features.

## Tag rules

Stable release tags are annotated tags of the form:

```text
v1.3.0
```

The tagged commit must be contained in `main`, and the tag must match `MARKETING_VERSION` in `Configuration/Version.xcconfig` at that commit. Do not move or reuse `v*` tags. Configure a GitHub tag ruleset that blocks updates and deletion for `v*`.

Dev tags are created automatically in the form:

```text
dev-124
```

where the number is the build number. They are intentionally temporary; the dev workflow retains the newest 14 dev releases and removes older dev releases and tags.

## Binary channels

| Channel | Trigger | GitHub release | Source file | Intended audience |
|---|---|---|---|---|
| Dev | Every push to `main`, or manual run | Prerelease | `apps-dev.json` | Early testers |
| Stable | `vX.Y.Z` tag on `main` | Full release | `apps.json` | General users |

The app's `MARKETING_VERSION`, set in `Configuration/Version.xcconfig`, stays numeric (`X.Y.Z`); the display version of a dev build (for example `1.3.0-dev.124`) appears in artifact names, release titles, and source release notes. Source `version` fields carry the numeric app version, because AltStore and SideStore refuse installs whose app version differs from the source. Build numbers are the commit count of the built commit in both channels, so a dev build and a stable tag of the same commit share one.

## Current installation behavior

Both channels use `moe.itoapp.ito`. A Dev or Stable installation therefore replaces the other.

To support side-by-side installs later, introduce Xcode configurations or schemes with separate values such as:

```text
Stable: moe.itoapp.ito
Dev:    moe.itoapp.ito.dev
```

That change must also review App Groups, keychain groups, URL schemes, extensions, associated domains, and other entitlements before the bundle identifier is overridden in CI.
