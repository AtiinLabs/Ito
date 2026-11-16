# Unsigned release process

Ito currently distributes unsigned device IPAs. AltStore and SideStore can re-sign them with the user's Apple account; TrollStore and jailbreak installation depend on the target device and environment. App Store/TestFlight signing remains a separate future workflow.

## Runner compatibility

The runner pin includes bounded, explicit chapter-edition enumeration and typed native host-call
timeouts. Network and web-page watchdog timeouts remain host failures, not plugin crashes, HTTP
server errors or network-policy waits. They do not evict the runner. A timed-out completion write
pauses instead of replaying automatically because its remote outcome may be unknown.
Edition-contract violations use the existing incompatible-source presentation. The optional
enumeration API alone does not start background or automatic traversals. Ito calls it only from the
explicit **Find All Uploads** action of the scanlator sheet (see Edition-policy checks); a manga or
novel source without the export gets an explanation there instead of a listing.

## Backup compatibility

Manual backups carry saved Library details and valid saved cover thumbnails through a separate
`savedLibraryThumbnails` capability. Export retains up to 16 MiB of thumbnails, newest first;
invalid, stale or over-budget cached thumbnails are omitted without changing the local Library.
Restore validates JPEG dimensions, encoded size, cover digest and Library identity before remapping
each thumbnail. A merge that keeps local details keeps its existing thumbnail, filling only missing
ones. Older backups without this capability remain supported.

The compatibility is one-directional. Every backup this version exports lists the
`savedLibraryThumbnails` capability, and earlier app versions reject an unknown capability component
(`unknownComponent`), so they cannot read these backups at all. Say so in the release notes of the
version that ships it.

Custom download presets travel in a separate `downloadPresets` component, which every backup from this version
lists (empty when no presets exist). Earlier builds reject these backups with `unknownComponent`, as they already
do for `savedLibraryThumbnails`. Backups from earlier versions have no such component and restore with local
presets untouched. Release notes must say that backups from this version need this version or later.

Snapshot freshness remains installation-local. Restored details do not prove current catalog
completeness. Backups still exclude downloaded chapter media, inventory pointers, queues, source
epochs and runtime permissions.


Schema v27 adds the automatic-download ledger (`seriesSubscription`, `subscriptionBaseline`, `subscriptionSeenKey`,
`subscriptionEvent`) and `downloadJobOwner`. The migration rebuilds `downloadBatch` (new `automatic` preset) and gives
every existing job exactly one manual owner named by its batch; no owner is ever inferred from a preset. Of the five new
tables, from v28 `seriesSubscription` travels as `automaticDownloadRules` (see below); the other four
(`subscriptionBaseline`, `subscriptionSeenKey`, `subscriptionEvent`, `downloadJobOwner`) are excluded and sanitized
child-first on export, so catalog evidence, job ownership and queued work never travel. Two scalar preferences,
`Ito.AutomaticDownloadQueueLimit` (10...500, default 100) and `Ito.AutomaticDownloadQuotaGiB` (1...200, default 5), are
part of the preference catalog, so backups from this version carry them; earlier builds reject those backups, and
backups from earlier versions restore with the defaults.

Schema v28 lets a backup carry automatic download rules through a separate `automaticDownloadRules` capability, which
every backup from this version lists (empty when no rule is kept). Export keeps the rules that are enabled or paused,
drops disabled ones, and reduces each to its choices (mode, window size, per-run limit, group selection, replacement
rule) as a new rule paused with the reason `restored`: generations, check tickets and attempt history are reset, and
no baseline, seen key, event, job owner, queue entry or source epoch is exported. Restore never creates a baseline,
event, owner or job and never touches read state, History or update badges. It inserts a rule only for a series that
is in the Library after the Library restore; a rule whose group selection this build cannot read is skipped. A wipe
restore deletes every local rule that no readable rule of the backup replaces (the jobs only they asked for go, saved
files stay), including the local twin of a skipped rule, and replaces a rule it does carry in place as a new
incarnation; a merge restore keeps a local enabled or paused rule and replaces only a disabled one. Backups from
earlier versions have no such component and restore with local rules untouched.
Earlier builds reject backups from this version with `unknownComponent`, so release notes must say that backups from
this version need this version or later.

Automatic checks of subscribed series run in the foreground only. The scheduler starts when the app is ready and active,
when a Library refresh ends, and when a rule is enabled, edited or resumed; a rule is due one update interval after its
last check, longer after a failure, and a refresh counts as a check. Checks follow the automatic-metadata network
policy (Wi-Fi only, Low Data Mode, unknown path) before every series, and a source that needs a sign-in or settings is
not asked again in that pass. The one background refresh, when the user opted into it, feeds subscribed series through
the same single fetch; the scheduler never runs in the background and nothing here promises background immediacy.
Downloads that only rules asked for run as automatic bulk work: they never mint, borrow or hold a metered-data consent
and wait under "Ask" on a metered path without holding back a person's batches. This slice adds no screen, string or
notification: the commands exist behind `AutomaticDownloads`, and no rule can be created from the app yet.

## One-time repository setup

1. Copy this starter kit into the Ito repository.
2. In **Settings → Pages**, publish from the `gh-pages` branch and `/ (root)`.
3. Protect `main`, require pull requests, and require the `Build and unit test` check.
4. Add a tag ruleset for `v*` that blocks tag updates and deletion.
5. Pin `ito-runner` and `anilist-sdk` in the Xcode project to reviewed commits; `Package.resolved` pins them and WasmKit for every build.
6. Ensure the repository's Actions token has `contents: write` for release workflows.

## Dev channel

CI validates every push to `main` once, then calls the dev packaging workflow only after its build/unit tests, localization checks and signing-configuration check succeed. The publisher checks out that exact validated commit; it does not repeat the unit suite. Pull requests run validation only.

For a manual dev build, use **Actions → CI → Run workflow → main**. The same validation gates apply. A newer push to `main` cancels an in-progress CI/dev run. Stable tagged releases retain their separate verification of the tagged release candidate.

It publishes:

```text
Ito-X.Y.Z-dev.BUILD-unsigned.ipa
Ito-X.Y.Z-dev.BUILD-unsigned.ipa.sha256
Ito-X.Y.Z-dev.BUILD-unsigned.tipa
Ito-X.Y.Z-dev.BUILD-unsigned.tipa.sha256
```

For example `Ito-1.3.0-dev.124-unsigned.ipa`. It creates a GitHub prerelease tagged `dev-BUILD` and titled `X.Y.Z-dev.BUILD`, updates `apps-dev.json`, and keeps the newest 14 dev releases, deleting older dev releases and tags. Dev builds may be unstable.

## App version and build number

`Configuration/Version.xcconfig` is the only place the version is set:

- `MARKETING_VERSION` is the numeric `X.Y.Z` version of the next stable release. It becomes `CFBundleShortVersionString`, is shown in Settings, and is compared with each plugin's `min_app_version`.
- The build number (`CFBundleVersion`) is the commit count of the built commit, `git rev-list --count HEAD`. Dev and release workflows set it, so the same commit has the same build number in both channels and builds increase along `main`. Local builds use 1.

Release tags must match the file: `v1.3.0` requires `MARKETING_VERSION = 1.3.0` at the tagged commit, or the release workflow stops. Tags with a suffix after the version are rejected.

`main` declares the version its contents would be released as. After tagging `v1.3.0`, bump `main` to the patch version `1.3.1` so dev builds stop claiming the released version. The first pull request after that which adds a feature also bumps the minor version (`1.4.0`); breaking changes bump the major version. The version on `main` only moves forward.

## Exact-edition update counts

Library schema v23 adds nullable `knownChapterCountBasis` (v22 is reserved for History).
Manga and novels count distinct byte-exact chapter keys, including alternate groups and
same-number splits; anime keeps its existing episode count. New nonempty saves establish
the exact-key basis. Older or unknown baselines silently adopt the first successful
nonempty current catalog without changing an existing badge or update timestamp.
Only later same-basis positive count growth adds to the badge. Failed/empty catalogs do
not establish a basis. This is an update-count heuristic, not a new-release detector.

Library backups preserve this metadata; missing/unknown values safely rebaseline.
Detail acknowledgment still requires the existing current-operation/visibility guards.
Read-number persistence and offline inventory counts are unchanged. Notifications and
Library accessibility describe manga/novel count growth as editions, not logical chapters.

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

The tagged commit must be contained in `main`. The workflow tests it, builds the unsigned IPA and `.tipa`, creates a full GitHub Release, and updates `apps.json`.

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

## Installing: AltStore, SideStore, Feather, TrollStore

After the first publication in each channel:

```text
Stable: https://atiinlabs.github.io/Ito/apps.json
Dev:    https://atiinlabs.github.io/Ito/apps-dev.json
```

AltStore, SideStore, and Feather read these sources directly. Both feeds describe the same bundle identifier. Installing one channel replaces the other.

Each source entry's `version` is the app's numeric version and `buildVersion` its build number, matching the IPA's Info.plist; AltStore and SideStore refuse an install when they differ. The channel display version (for example `1.3.0-dev.124`) goes in the entry's release notes. Every entry also carries the IPA's `sha256`, which both stores verify after downloading.

Every release also carries a `.tipa`, byte-identical to the IPA, for TrollStore. TrollStore fake-signs the unsigned app with ldid on install; Ito needs no entitlements beyond TrollStore's defaults.

GitHub release notes strip custom URL schemes, so the one-tap links live on GitHub Pages:

- `https://atiinlabs.github.io/Ito/` is the site, `site/index.html` on `main`. `.github/workflows/site.yml` copies it to the root of `gh-pages` whenever `site/` changes on `main`, or when started manually. Its install selector targets Stable: AltStore, SideStore, and Feather add `apps.json`; TrollStore installs the `.tipa` named by the latest `apps.json` entry, fetched when the page loads.
- `https://atiinlabs.github.io/Ito/install/` is regenerated on every feed and site publication from the sources present (`.github/scripts/render_install_page.py`). For each channel it links `altstore://source?url=`, `sidestore://source?url=`, `feather://source/<source URL>`, `apple-magnifier://install?url=<.tipa URL>` (TrollStore), and the direct downloads.

Feed and site publications push to `gh-pages` independently through `.github/scripts/gh_pages.sh`, which redoes an update when another publisher landed first. GitHub Pages must deploy from the `gh-pages` branch (**Settings → Pages → Deploy from a branch**); otherwise the feeds are committed but never served.

## What each publication does

1. validates the tag or dev build metadata;
2. checks out Ito;
3. resolves Swift packages;
4. runs unit tests on an available iPhone simulator;
5. archives a generic iOS device build with signing disabled;
6. removes stale signatures and provisioning profiles;
7. packages `Payload/Ito.app` as an IPA and a `.tipa` copy;
8. creates SHA-256 checksums;
9. publishes a GitHub release or prerelease;
10. updates the channel-specific source and the builds page (`install/`) on `gh-pages`.

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

## Edition-policy checks

Before releasing changes to download selection, verify legacy v1/v2 preferences retain their
meaning. Preferred-group fallback policies use v3; unknown versions and missing group identities
must require review rather than silently broadening selection. Approved fallback groups may
substitute only for a source-proven logical position, and existing permitted saved copies must not
be upgraded merely because the primary group returns.

Confirm that Ask presents one aggregate batch decision, Cancel queues nothing, and a changed
catalog or source session invalidates the old confirmation. Remember must wait for persistence;
an admitted save that outlives its sheet must refresh authoritative preferences without restoring
removed Library scope or reporting stale success.

Another open screen for the same series may hold an older copy of the policy. A reviewed batch
carries the policy it was planned under, and the store refuses it in the write transaction when the
stored policy differs, so verify the second screen cannot queue another group after the first
narrows to Strict.

Find All Uploads is the only caller of the optional edition enumeration. Verify that opening or
refreshing a series, presets, the scanlator sheet itself, readers, subscriptions and local
alternatives make no such call. Every manga or novel source that runs through a runner shows the
button; a source without the export answers with an explanation and an unchanged chapter list. The
listing is an ephemeral catalog for the open sheet: it is never written to the Library item, saved
snapshot, chapter counts, History or any baseline, and it is not merged into the chapter list.
Uploads queued from it do appear in the detail list afterwards as saved-only rows once they are
downloaded, through the existing inventory; that is expected. Check that the sheet states what the
listing claims: complete within the source's scope, possibly incomplete, only the uploads the source
shows by default, or stopped at an Ito cap (the upload cap names the number actually listed), and
never calls a partial or bounded listing complete. Rows show their saved, queued or failed status
as it is while the sheet is open; a failed upload points to the Downloads queue, which has Retry.
Dismissing the sheet, changing the series, and refreshing it to a different chapter list end the
listing, and a late answer shows nothing. A source settings or account change does not end a
running listing; it makes the listing stale: its answer is discarded when it finishes and queueing
from it is refused, and the sheet asks for review. A failure keeps no rows and is not retried.
Ticked uploads queue through the shared batch as the exact chapters the source listed, under the
source epoch and remembered policy the sheet was reviewed under; locked uploads stay blocked and no
group choice is remembered unless the sheet's own Remember flow is used.

## Manual offline replacement candidate

See [Offline chapter replacement](OFFLINE_DOWNLOADS.md) for the v24 schema, conservative recovery and release acceptance suites. Replacement is manual-only: do not advertise automatic refreshing or guaranteed newer content for unknown source revisions. Verify localization after the clean simulator build and retain lease/delete/recovery race coverage before publication.
## Network preference upgrade checks

Network preferences are scalar GRDB configuration, not runtime permissions. Upgrade and older-backup restore derive a missing adjacent-chapter prefetch amount once from the stored image preload (zero → zero, positive or absent → two); explicit values survive. No database schema migration is needed.

An explicitly represented-empty scalar restore remains empty. Refresh derives dependent network keys only when a stored preload exists; it does not materialize defaults for an empty or no-preload partial snapshot. Publishing already downloaded, verified bytes is local work: P5 retains source/runtime/trust/job validation, not soft network admission.

Before shipping network changes, exercise `NetworkPolicyTests`, `NetworkPreferenceMigrationTests`, `AppSettingsStoreTests`, `NetworkSettingsViewModelTests`, `DownloadNetModuleTests`, `DownloadCenterBatchTests`, `DownloadAttemptTests`, `UpdateRunTests` and reader prefetch suites. Confirm metered permission is limited to one foreground batch and expires on background, source, path-class or policy change. Reset affects only download mode, Wi-Fi-only automatic checks, image preload, adjacent prefetch and novel prefetch. Runtime grants and effective values must not appear in backups.

Network policy regressions also include `NetworkConsentAdmissionTests` and `ReaderNetworkPolicyTests`: exact capability incarnation/source/operation lineage, foreground grant revocation during a held transfer, speculative-versus-interactive continuous manga admission, and novel start/publication races and manual continuation under effective restrictions. Their barriers do not depend on sleeps or notification-task ordering.

Speculative reader work (image preload, adjacent manga chapters and novel prefetch) never runs on a cellular, personal hotspot or Low Data Mode path, whatever the download mode is. Those settings are off there by default, and no metered consent turns them on. The default download mode remains Unmetered Only.

"Ask on Metered Networks" applies the same foreground confirmation to a single-chapter download as to a batch. Cancelling one chapter keeps the batch's consent for its remaining chapters; the consent ends when the batch has no jobs left, the app leaves the foreground, the path class changes, or the download mode changes. A job waiting for a metered network offers Cancel only, not Retry: the wait clears when an unmetered network is available, and a queued job cannot be granted metered consent after the fact. Cancel it and download the chapter again to be asked.

Backups written by this build carry the new `Ito.NetworkDownloadMode` and `Ito.AdjacentChapterPrefetchCount` keys. Older app versions require an exact scalar-key catalog and reject backups containing these new keys; restore them only on a current build.

Source transport enforcement (see `docs/NETWORK_TRANSPORT_ENFORCEMENT.md`) changes two things users notice once after upgrading. Source covers and images cached by earlier builds are not reused: they download again the first time they are shown, under the network policy. Source website data now lives in nonpersistent per-source stores, so earlier Cloudflare clearance cookies are not used and a protected source shows its verification page again. Before shipping, observe a real WebKit challenge (including `about:blank` frames and a backgrounded challenge) and AVPlayer playback across Low Data Mode and cellular changes on a physical device.

For custom download presets, verify native import rejects physical preset rows without a represented
capability before loading their payloads, and invalid definitions cannot be exported. Editing or
deleting a definition must not alter an open chooser or preview, even after a chapter catalog refresh:
the chosen name, rule and batch provenance remain frozen. Without a last-read anchor, More starts
at the first unread position and skips saved or queued chapters; it makes no reading-history claim.
Unreadable preset recovery must show a failed Delete All operation and preserve the stored rows.

## Downloaded-alternative checks

Before releasing changes to the chapter menu's "Choose Downloaded Version…", verify that it opens exactly
one saved copy the user selected, for this reading only. The list holds only verified copies of the same
source-supplied logical unit under the same metadata origin; number, title and group never match, and an
upload that is no longer in the catalog is still listed. Several choices start unselected and a single one
still needs confirmation.

Confirm that choosing, cancelling, a failed lookup and a failed lease write no progress, History,
tracker, preference or queue state, and call no plugin. A deleted, replaced, retagged or damaged copy, a
locked device and a rotated source epoch fail instead of opening another copy, and the opened chapter
never reads from the source, including on retry. The reader opens only after the sheet has closed; a
dismissal that is stale, cancelled or from another presentation opens nothing and leaves no lease.
Ordinary local-first reading, Read Online This Time and the source fallback for a damaged copy are unchanged.

## Image/text reader handoff checks

A reader opening is one route. When the chapter after (or before) the one being read is made for the other
reader, the route moves between the page reader and the text reader inside the same full-screen cover; the
series screen, its navigation path and the closing gesture do not change. Which reader a chapter is made for
comes from its saved copy's manifest form when it is read from a saved copy, and otherwise from the form the
catalog declares (the chapter's own kind, else the series default); the pages themselves are never used to
guess it. A chapter found to be made for the other reader than the one that was asked to open it (the first
chapter of a route, or one a reader had nothing on screen for) is opened by the right reader at its
beginning (at its end when the page reader was crossing backwards): the saved position is one number
shared by both forms.

What the implementation guarantees, and what the unit tests exercise:

- A neighbor the catalog declares as the other form is prepared and laid out behind the visible reader, which
  stays mounted with its own pages, position and image leases until the destination can be drawn.
- A neighbor declared as this reader's own form that only turns out to be saved as the other form is found
  out by the source reader loading it. That reader shows its loading screen first, is then put back at the
  place it was at (the page it was on; for scrolling, that page as an unanimated scroll target; for text,
  the last place it reported) and hands off with what was loaded. Nothing is written for either chapter
  while it waits. Pressing Next again while that load runs has nothing to put back, so a second chapter that
  turns out to be the other form replaces the reader on screen, as does Try Again after a failed load.
- A failed handoff (a failed load, a chapter that is locked, not downloaded, damaged or protected, an empty
  chapter, a first image or layout that cannot be drawn) leaves the source reader as it was and shows a
  retry/cancel notice, which is also announced to VoiceOver; the source is hidden from VoiceOver and
  touch while a handoff is pending. A cancelled or stale one (Cancel, source scope, continuation setting,
  leaving the foreground, the source navigating on) is silent: the source reader is as it was and nothing
  is shown. Navigating in the source clears a failure that was shown for an earlier crossing.
- Nothing is recorded for the destination before it is shown: no History row, position write, completion,
  tracker update, presence or adjacent prefetch. Once it is shown, a text destination saves its first place,
  as the page reader does.
- A chapter that was loaded for the destination is reused for the swap, and for a consent prompt that was
  raised after the source had already loaded it. It is prepared again when the network policy or path
  changes while it is still loading (under the policy now in force, after the original request is checked
  as it was), and by Try Again after a failure.
- The destination's first image is held until it is ready and its renderer holds a lease of its own, or
  until the swap; the renderer taking a lease alone does not release it, and a failed image fails the
  handoff.
- History and completion are claimed once per exact chapter key for the whole route, a pending tracker step
  of the retired reader still runs after a swap, and position writes stay in order across readers.
- A different-group neighbor asks for the same one-upload consent before any destination request when "Ask
  before switching groups" is on (off by default); the answer is not remembered. A chapter whose saved copy is
  of another form than the catalog says stops a same-reader append or prefetch at that boundary instead of
  being appended into the wrong reader. The text reader's paged mode shows a notice before its first page
  only for a neighbor that opens in the other reader; a locked, not downloaded or other-group previous
  chapter behaves as before.

Not observed: the rendering. No simulator or device recording of the seamless swap, the continuous-reading
edge crossings, the paged edge notice, the consent alert on the route, RTL paging or VoiceOver was made
with this change. The "drawable" handshake (first image decoded and held, first paged text layout applied,
first continuous scroll position acknowledged) is verified at the session and coordinator level with
explicit barriers, and the continuous renderer's end-of-scroll crossing and first-layout report are driven
through the real view controller in a window; none of it is observed on screen. Before shipping, exercise a
page→text and text→page crossing in both catalog kinds, paged both directions, continuous both directions,
Cancel at a held load, the late answer after Close, the A→B→A History rows, a selected saved copy opening and
continuing offline, and a corrupt or protected copy failure, on a device, and read the screen. The text
reader's paged mode continues past its last page only through the visible notice (no swipe past the end),
and its continuous mode crosses by the user's own scrolling to the end row; both are by design, not
oversights. One-time notes: the boundary notice strings and the "Opening the next/previous chapter…" status
are new localized text.
