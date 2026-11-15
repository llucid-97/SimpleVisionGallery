<!-- Target audience: humans and agents -->
# Core requirements

These are the Gallery behaviors we protect on every release. They apply to Photos and the unlocked vault equally. They are required review checks before full-send. This list grows when Gershoma adds a requirement.

## Fast browsing stays fast

Navigating to locally available, prepared media must reuse that work, with no repeat fetch, decrypt, decode or scene generation. For warm video, maintain the accepted roughly 50–100 ms first-visible-frame baseline below. Less than 50 ms remains a stretch goal, not a release requirement for video. Prepared still images and mutation action handling retain their existing under-50 ms aims. Report samples and worst cases, not just an average: a cache hit followed by a blocked render thread fails too.

Keep ahead/behind preparation working across navigation, shuffle, album changes, move, delete, restore, bin actions, settings changes and multiple windows. Unrelated mutations must not discard prepared next items or block rendering. A same-byte membership change must not force decoding again. Shared work must survive one window cancelling while another still needs it. Closed windows must give back their cache share.

Video lookahead uses one global speculative player across Photos and vault items. Prepare only the next video at full quality; rely on existing library metadata for later videos until they become next. Wait for both the item and player to become ready, preroll at rate 1 while paused and muted, and let the first foreground window take that player and item. Other windows create independent players over the shared asset and lease. A short forward-buffer duration is only an AVFoundation hint, not a RAM cap; restore normal adaptive buffering on foreground handoff. Keep this decoder slot separate from the 20-item/80-million-pixel still-image cache and the existing vault plaintext disk lease. Cancel stale warm work and release its player on close, lock, Photos revocation or memory warning.

Cold media, network downloads, scene generation and intentional privacy invalidation can take time. Label those cases separately; they are not excuses to call a warm miss a pass. Vault lock and revoked Photos access must clear protected content immediately. Unlock rebuilds safe demand and prepares again. Keep preparation bounded: 20 results, 80 million pixels and two preparation jobs shared across windows. Do not gain speed by growing unbounded caches or storing vault plaintext outside leases.


### Accepted warm-video performance baseline

Gershoma accepted build `3ca9061078dcf1fb8a1223104ceff07ffefed7ad` ([PR #30](https://github.com/llucid-97/SimpleVisionGallery/pull/30)) on Pali on 15 November 2026 as fast enough. Preserve that experience in future updates. The headset acceptance is a user judgment; no numeric headset latency was measured.

| Measurement | Accepted reference |
| --- | --- |
| Navigation action → first visible video pixels, warm Simulator sample | 48.68–99.23 ms; median 75.96 ms; 10 transitions |
| First warm transition in that run | 76.19 ms; initial cold open excluded |
| Practical target for comparable warm-video checks | Roughly 50–100 ms, aiming for 100 ms or less |

The ten visible-frame upper bounds were `76.19, 75.73, 82.40, 84.47, 64.16, 48.68, 73.02, 99.23, 70.18, 97.24` ms. They came from the production viewer's navigation/load/cache path over generated encrypted vault records: alternating eight-second, 1920×1080, 30 fps mono videos, using the spatial-video Simulator preview, Xcode 27.0 and visionOS 26.1 Simulator. The same warmed player and fitted native entity reached the foreground in every transition. Video-to-video reuse was measured; image-to-video timing was not established by this run.

The measurement used visible source pixels and ScreenCaptureKit display timestamps on the same verified host clock. Each sample is an upper bound with a 16.67–21.08 ms last-negative/first-positive frame gap. An earlier candidate run had a 156 ms first warm sample. These results are a realistic reference, not a guarantee that every transition is under 100 ms.

For changes affecting loading, playback, preparation or window lifecycle:

- Compare at least ten warm transitions, including the first warm transition, against the accepted build under matched fixtures, build configuration, machine, capture method and workload. Keep cold, network and privacy-invalidated cases separate. Test the affected Photos/vault, mixed-media and multi-window transitions as well; the measured vault sample does not prove those timings.
- Measure navigation → visible pixels. Player readiness, attachment, playback-clock progress and cache hits are diagnostic values, not substitutes. Never subtract marker or capture latency to claim the target.
- Report every sample, median, maximum, frame gaps, source revision and tested states. Investigate repeatable moves beyond roughly 100 ms, a consistent slowdown against the matched baseline, or newly visible stalls. Preserve isolated outliers and repeat the comparison before blaming a code change; do not turn one noisy sample into a universal pass or failure.
- Reviewers must record that comparison or explain why a change cannot affect this path. Keep the existing image, mutation, privacy and memory contracts. Do not trade full quality, spatial playback, correct item identity or bounded resources for a timing score.

The video host stays mounted across consecutive videos and unmounts for images: overlapping native RealityViews hid photos in the generated control, and opacity did not fix it. Preserve photo visibility when changing this arrangement. Actual spatial appearance, memory behavior and headset responsiveness still require the owner's test when affected; Simulator mono results do not establish them.

## Move feels as immediate as Delete

After choosing a Move destination, capture the exact displayed item and destination, advance at once and keep navigation usable while the move runs. Repeated moves queue without losing or retargeting an item. Hide pending removals in the source playlist/grid and sibling windows. Work runs off the UI thread; library or vault writes and later metadata refreshes must not freeze the next frame.

A failed item returns with an error; successful items stay moved. Keep queue order, visible pending counts and the existing delayed Photos warning. Lock, cancellation and crash must never move an untapped item or leave a partial vault record. Preserve each source's move/restore semantics and Photos system prompts. Test new and existing destinations in viewer and grid, Photos and vault.

## Recycle Bin treats vault items as first class

Unlocked Recycle Bin includes binned vault items. Put Back preserves their surviving memberships; Delete Permanently and Empty Bin delete them directly from the vault, after the permanent-action confirmation. No restore to Photos is required. Frozen target IDs bound the operation: later additions are not included. Cancel changes nothing. A failed item stays recoverable; other safe work can finish.

Vault deletion must never remove Photos assets. Mixed Photos/vault bulk actions handle both stores using their own safe paths, report partial failure and honor lock. Locked vault items and their counts stay private. Bin membership must never appear as an album destination or be recreated in Photos.

## Recent Move albums work for both stores

Remember the last N successful Move destinations for Photos and vault albums, including newly created vault albums. Use the same recency order and limit, remove duplicates, and move a reused destination to the front. Names are display values, not identity. Filter unavailable, deleted, source and reserved-bin destinations; do not leak vault titles while locked. Preserve existing Photos history when upgrading.

## Sharing preserves supplied media

The incoming Share extension accepts supported photo and video representations and saves a copy to the chosen Photos or Private Vault destination without decoding or recompressing it. Vault-bound shares are encrypted on device, stay out of Photos, and are imported when the vault is unlocked; interruption, lock, and retries must not lose or duplicate them. It uses a safe sender filename when available, leaves the source untouched and requests Photos add permission only for the Photos destination. Cancel dismisses promptly while staged files remain until an in-flight provider callback finishes. The existing Photos grid and viewer Share actions continue to export original resources.

`python3 tests/check_sharing_input.py` verifies concrete image-type selection, suggested and fallback filenames, temporary-provider callback lifetime, exact copied bytes, unsupported input and provider failures.

`python3 tests/check_sharing_vault.py` protects the encrypted intake protocol: exact bytes, stable key derivation, wrong-key and key-rotation rejection, tamper detection, truncation, and trailing bytes. Native authentication and sandbox handoff are separate checks.

## Scripted transition coverage

Maintain a code-backed inventory of the implicit loading states and every reachable transition. When code adds a transition, add its test. Use a controlled backend for delays/failures and generated real PhotoKit/encrypted-storage fixtures for store boundaries. A source-string check alone does not prove runtime behavior.

| Start or event | Required result |
| --- | --- |
| Cold open → load → ready → prepare ahead/behind | Current completes; ordered next/previous demand starts and stays within bounds. |
| Ready → Next/Previous, wrap, shuffle or sort | Correct item, warm reuse, no stale completion replacing the current surface. |
| Preparing → foreground promotion → rapid next/cancel | Join wanted work; cancel only work with no consumers; foreground is not starved. |
| One window → two windows → close/background/resume either | Shared request remains live for remaining consumers; fair budgets recover; resumed demand runs. |
| Show/dismiss More, Move or Settings; toggle Original/Scene | Covering a surface does not kill preparation; scene/original identity stays correct. |
| Pending Move/Delete → success/failure, source playlist changes | Immediate successor stays prepared; exact item changes; failure restores only that item in every window. |
| Photos → vault; vault → Photos; vault membership move | Retire invalid source safely, preserve unrelated cache entries, prepare destination items. |
| Bin → Put Back/Delete Permanently/Empty Bin, mixed stores | Frozen IDs only, cancel unchanged, no cache resurrection or unrelated deletion. |
| Unlocked → lock mid-load/mutation → unlock | No private surface/lease survives lock; safe committed prefix only; new demand can load after unlock. |
| Photos access revoked/limited; external edit/removal | Revoke stale content and cache identity; show a recoverable state; no stale overwrite. |
| Memory warning, budget rejection, generation failure → retry | Respect bounds; transient failures do not suppress valid preparation forever. |
| Larger/smaller ahead/behind settings; window closes | Retentions and pending jobs follow demand; released capacity is usable again. |

At minimum, run sequential and shuffled playlists, 1k and 10k vault records, a large Photos album, mixed image/video items and two windows. Compare exact before/after record and Photos ID sets for mutations. Measure action handling, first visible frame and later frame gaps separately while jobs are delayed. Record warm/cold classification, source revision, fixtures, tested transitions, failures, cache/memory limits and hardware gaps. Missing coverage is unknown, never green.

## Release checklist

- Run `python3 tests/run_core_checks.py` through the shared compute queue and the relevant native build on the final integrated revision.
- Run generated Simulator transition checks for changed loading, queue, storage or window behavior; shut down the owned Simulator afterward.
- Review the four requirements above, with a result and evidence for each. An untested path or known failure must be visible in the handoff.
- Check that tests fail for the regression they guard, cover failure/cancel/lock and verify IDs rather than counts alone.
- Check logs and fixtures for privacy. Never inspect the owner's headset without permission for that occasion.
- Keep headset-only appearance checks distinct: spatial scenes and dual-view comfort require Gershoma's headset test.

## Dual-view calibration

This is a requested feature, separate from the four core rules. Provide saved yaw and pitch controls with degree values and Reset so Gershoma can tune inward angle and tilt for spatial images, scenes and videos. Use the same transform for native media and its backing. Simulator tests can check settings and transforms; they cannot establish spatial-scene appearance or comfort.
