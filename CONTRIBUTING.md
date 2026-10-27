# Contributing to Ito

Ito uses a trunk flow: all work merges to protected `main` through reviewed pull requests, every push to `main` publishes a Dev build, and an annotated `vX.Y.Z` tag on `main` publishes a Stable build.

## Local setup

Clone Ito and open the project; Xcode fetches `ito-runner`, `WasmKit` and `anilist-sdk` from GitHub at the revisions pinned in `Package.resolved`:

```bash
git clone https://github.com/AtiinLabs/Ito.git
open Ito/Ito.xcodeproj
```

To work on `ito-runner` or `anilist-sdk` alongside Ito, clone it anywhere and drag its folder into the Xcode project navigator; a local package overrides the remote one with the same name until you remove it. To ship the change, merge it in that repository, then update the revision in **Package Dependencies** (or the package requirement in the project) and commit the new `Package.resolved`.

A paid Apple Developer Program membership is not required for simulator development or the unsigned CI builds.

### Linting

SwiftLint runs in the Xcode build, in a pre-commit hook, and in the `SwiftLint / lint` check on every pull request. CI treats warnings as errors. Install the hook once per clone:

```bash
brew install lefthook swiftlint
lefthook install
```

The hook lints staged Swift files. To lint everything, run `swiftlint lint --strict`; `swiftlint --fix` corrects what it can.

Compiler diagnostics are separate from SwiftLint. Check the `Ito` scheme's build and Analyze results too, and fix warnings at their source rather than suppressing them.

## Branches

Create short-lived branches from current `main`:

- `feat/<brief-name>` for user-facing work
- `fix/<brief-name>` for ordinary bug fixes
- `refactor/<brief-name>` for internal restructuring
- `chore/<brief-name>` for maintenance
- `docs/<brief-name>` for documentation

There are no release or hotfix branches and no permanent `develop` branch. `main` declares the next stable version in `Configuration/Version.xcconfig`; a stable release is an annotated tag `vX.Y.Z` on `main`.

## Pull requests

1. Keep each pull request focused and reviewable.
2. Include screenshots or a recording for meaningful UI changes.
3. Let GitHub Actions pass before merge.
4. Use squash merge.

Use a Conventional Commit-style pull-request title, such as:

- `feat: add account switching`
- `fix: prevent duplicate timeline requests`
- `chore: bump version to 1.3.1`

## Testing without signing

CI builds and tests with code signing disabled. Locally, select an iOS Simulator and run the `Ito` scheme. Do not commit signing identities, `.p12` files, provisioning profiles, Apple account details, or personal development-team identifiers.

To run on a device, set your team in Xcode and leave that change uncommitted. The pre-commit hook and the `CI / No development team` check reject a `DEVELOPMENT_TEAM` value in `project.pbxproj` or an `.xcconfig` file. If you stage the project file for another change, stage only the hunks you mean to commit (`git add -p`).

### Plugin WebView scripts

Starting with Ito 1.4.0, a script passed through the existing WebView execution
API can opt into an asynchronous function body by starting with the exact line
`//# ito-async` followed by a newline:

```javascript
//# ito-async
return JSON.stringify(await Promise.resolve({ supported: true }));
```

This path runs in the page's content world and awaits a returned Promise. Use
`return` explicitly, and serialize structured results with `JSON.stringify`.
Scripts without this prefix retain their existing program-evaluation behavior.
No SDK or WASM import changes are required; plugins using the capability must
declare `min_app_version` of at least `1.4.0`.

Caller cancellation or a replacement document ends the host's wait and discards
late results. It does not abort JavaScript already running in the page. The
runner's existing host-call timeout remains the deadline authority.

Plugins can also ask Ito to show the shared WebView to the user, for a verification
the host can't complete itself (such as a Cloudflare Turnstile dialog). Post to the
`itoShowPage` message handler in the page content world and await the reply:

```javascript
const shown = (await window.webkit?.messageHandlers?.itoShowPage?.postMessage(null)) === true;
```

The reply is a boolean: `true` when the page is shown (or already shown), `false`
when it is refused. The message body is ignored. Ito shows the page only while all
of these hold: the message comes from the page's main frame; an async script from
the plugin is waiting on that page; the app is in the foreground; and the user
hasn't closed a page for this origin since the app last became active. Ito never
clicks, detects a challenge, or polls. The user completes the verification, and the
waiting call continues.

When the user taps Close, or uses the VoiceOver escape gesture, every script waiting
on the page fails with `ItoError.hostModuleError(domain: "webview", message:
"Verification was closed.")`, and the origin is declined until the app becomes active
again. The page is hidden when its last waiting script ends, whether by completion,
rejection, cancellation, or a navigation that replaces the document. A waiting call
is still bounded by the webview host-call timeout (60 seconds, `HostCalls.swift` in
ito-runner). That limit counts from the start of the call, not from when the page is
shown, so a slow check can be cut short: the page hides and the call fails, and the
next call shows the page again.

## Build channels

- **Stable:** tags such as `v1.3.0`, created only on a commit already contained in `main`.
- **Dev:** built automatically from every push to `main`; intended for early testing.

Both channels use the same bundle identifier, so installing one replaces the other. Side-by-side channel installs require separate Xcode configurations, bundle identifiers, and entitlement review.

See `docs/BRANCHING_AND_CHANNELS.md` and `docs/RELEASING.md`.
