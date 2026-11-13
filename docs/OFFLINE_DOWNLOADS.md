# Offline chapter replacement

Manual **Replace download** is offered for a verified manga/novel chapter still listed and unlocked by its installed source, and only while no replacement of that chapter is in progress. Confirmation freezes the exact installed version and exact target chapter snapshot. The confirmation names the saved and new group and title and shows both revisions. Known differing revisions mean changed content, not necessarily newer content; missing or unchanged revisions are presented as **Download again**, a manual refresh. There is no automatic replacement preference or automatic replacement behavior.

`downloadReplacementIntent` (migration v24) belongs to a queue job and cascades on job deletion. It records the expected installed version/revision, target revision and source epoch. `authorizationId` is a UUID minted for each user confirmation, not a network permission. The existing manual-download network admission still applies. The v24 migration also rebuilds `downloadJob` to admit three terminal failure reasons (below); SQLite cannot widen a CHECK in place.

The existing P1–P5 protocol stages and verifies a separate immutable version. Admission retains the old copy and requires room for the new copy above the reserve plus the old copy's bytes; no old bytes are evicted to make room. A replacement that lacks that room waits for storage without holding back ordinary jobs, and it is readmitted only when the room exists. Because the source ABI does not promise revision-pinned page acquisition, the dedicated runtime re-reads the same exact chapter before acquisition and after staging.

A confirmed replacement that no longer applies ends rather than waits. Its job becomes `failed` with one of three reasons, its intent is removed, and the saved copy stays readable:

- `replacementStale`: the saved copy changed (pointer, damage, identity, suppression), or the source epoch moved on from the one the replacement was confirmed under.
- `replacementContentChanged`: the source's chapter is missing, ambiguous, locked, in another group, or has a different revision, or the target was not confirmed for the attempt.
- `replacementInterrupted`: the app restarted before the replacement was verified. Its confirmation was ephemeral and is never rolled forward.

Retry never revives an ended replacement; the downloads list does not offer Retry for one. Instead, Replace is offered directly on the chapter's menu, and a confirmation supersedes the ended record in one transaction. Suppression tombstones are not cleared by that supersession.

Retry never re-stamps a replacement's source epoch. A replacement keeps the epoch it was confirmed under; Retry or a resumed restore either requeues it when that epoch still applies or ends it as `replacementStale`.

P5 checks the live job/staging identity, ephemeral confirmation against persisted intent, expected verified inventory pointer/revision/identity, source epoch, suppression, target revision and existing runtime/trust guard in the publication transaction. It updates the existing inventory row only after all checks pass. A commit refused for a stale runtime requeues the job and keeps its intent. Reading progress and History are unchanged. New readers get the new pointer; active leases keep reading old immutable bytes until their last release permits reclamation. A crash after the new pointer commits but before the old version is reclaimed leaves an unreferenced version that the next reconciliation collects.

## The chapter's menu

- The chapter's row icon shows the saved copy's own state. A replacement does not change it: the copy stays downloaded and readable while a replacement runs.
- While a replacement has activity, the menu header names it: **Replacing download** (queued or running), the waiting reason (waiting), **Replacement failed** (a failure that Retry can address), or the ended reason (`replacementStale`, `replacementContentChanged`, `replacementInterrupted`). Without activity, the header is the copy's own state, as before, where that state explains the next step.
- Actions while a replacement has activity:
  - queued or running: **Cancel Replacement**;
  - waiting: **Retry Download** where only Retry can clear the wait, then **Cancel Replacement**;
  - failed and retryable: **Retry Download**, then **Cancel Replacement**;
  - ended: **Replace download**, then **Cancel Replacement**. Cancelling an ended record dismisses it; the saved copy stays.
- **Read Online This Time** and **Delete Download** stay listed beside any activity, so the saved copy is never hidden by a replacement.
- With no replacement activity, the menu offers the copy's own actions: Read Online This Time, Replace download, Delete Download.

Cancelling a replacement, deleting the copy and cancelling an ordinary download never delete the saved copy except where the user chose Delete.

## Replace refusals

A refusal says why, and only the reason that deletion would fix advises deletion:

- A copy saved under another series, or from an older source epoch (its source settings changed after it was saved), gets **This copy can't be replaced.** with the advice to delete the saved copy and download the chapter again.
- Anything else (no verified copy, a locked or unlisted chapter, a damaged copy, or a replacement already in progress) gets the generic **This chapter can't be downloaded.** and no delete advice. The saved copy is not touched.

## Delete and recovery

Restart loses ephemeral confirmation. Recovery never rolls a replacement forward, even with a permissive ordinary-download recovery guard: it retains the old pointer, discards unreferenced staging, and ends the replacement as `replacementInterrupted`. Delete Download removes the inventory, job and cascading intent and records exact suppression in D1 before cancelling the task. Queued-only deletions are suppressed too, so late publication cannot resurrect the edition.

## Release acceptance

Run `OfflineChapterStoreReplacementTests`, the `OfflineChapterStore*Tests` suites, `DownloadAttemptTests`, `DownloadReplacementWorkerTests`, `DownloadCenter*Tests`, `MediaDetailDownloadActionTests`, `MediaDetailDownloadBatchTests`, and `DurableStateSchemaTests`. Replacement coverage includes held source acquisition, changed or missing targets, deletion, pointer/relink/epoch/damage races, missing live confirmation, restart and P1–P4 recovery, a Retry or restored resume after an epoch change, a commit refused for a stale runtime, a crash before old-copy reclamation, lease retention/release, insufficient storage beside an ordinary job, the menu's activity actions, direct Replace after an ended record, and refusal wording for locked, unlisted and older-epoch copies. Parent integration must perform the clean simulator build, localization sync/check, and independent migration/release review on the final candidate. Source revision correspondence remains a provider contract; unknown revisions never prove freshness.
