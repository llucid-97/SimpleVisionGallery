<!-- Target audience: humans -->
# App Store release record

## Update 1.0.13 — Waiting for Review

Submitted **28 October 2026 at 22:31 GMT**, with automatic release after approval and no phased rollout. The update includes the faster prepared-scene transitions already dogfooded in 1.0.12, the Discord feedback link in About, four landscape screenshots, an 18-second preview video, and the owner's edited description and promotional text. Existing support email, free availability, privacy answers and rating are retained.

- Product source: `2b460623a1b54f4b6389cd2f67a6ce3930bbe6e7`; both version fields `1.0.13`. Later release-record commits do not change the uploaded app.
- Processed build: `a740e3bb-7bc6-43f7-86af-3f7ef4965de8`.
- [App Review receipt](https://appstoreconnect.apple.com/apps/6821613011/distribution/reviewsubmissions/details/c8bd8fdc-909a-4626-85b1-de36681fa9e4).
- Archive `job-12962`, signed export `job-12963`, upload retry `job-12981` succeeded. Strict signature, distribution profile, bundle identity, version and privacy-manifest checks passed. The first upload lost its queue worker; its owned orphan was stopped, and App Store Connect was checked before one retry. Apple received and processed the new build before selection and submission.
- Native Simulator build and focused About checks passed (`job-12957`–`job-12961`); the actual Discord link handed off to Safari (`job-12980`). Six reviewers inspected the final changed About and privacy text. The parent recorded 12 absent issues and 24 inapplicable checks for that static scope. This does not certify keyboard focus or headset gaze/stereo behavior.
- No new headset test was performed for 1.0.13. The cache implementation is unchanged from the owner-tested 1.0.12. Generated scenes and stereo appearance cannot be validated in Simulator. Existing marketing captures were retained at the owner's request.

## Update 1.0.11 — Ready for Distribution

App Store Connect showed **Ready for Distribution** on 28 October 2026. The following records its original submission.

Submitted **27 October 2026 at 15:51 GMT**, with automatic release after approval and no phased rollout. At that submission, public version 1.0.10 remained available while Apple reviewed the update. Free pricing, availability, privacy answers, screenshots and review contact remain unchanged.

This update improves the transition to the next prepared photo after a Recycle Bin move, keeps the Move sheet visible in side-by-side slideshows by hiding both raised surfaces, and adds vertical clearance around portrait media without changing window widths.

- Source: `95732af3b5699271a97e73529c8f60c027f410b8`; version/build `1.0.11`.
- Processed build: `60e63b6e-fce9-4037-92f3-0a9955ac1d5c`.
- [App Review receipt](https://appstoreconnect.apple.com/apps/6821613011/distribution/reviewsubmissions/details/b264b037-f07b-47f8-8a6a-0fc1d2826f9c).
- Release archive `job-12762`, official distribution export `job-12764`, and upload `job-12767` succeeded. Distribution signatures passed strict verification; both version fields and bundle identity were checked.
- Code review found no blocker. Existing scheduler, mutation and 100,001-item index evidence was reviewed. Fresh native Simulator captures cover portrait viewers, both Move entry points and restored media. Six visual reviewers completed 36 checks; the parent recorded 22 absences, 7 inapplicable checks and 7 coverage gaps. This is not a full pixel-peeping pass. The disabled native Create and Move styling was verified unchanged from 1.0.10 and was not accepted as a new defect.
- No new UI or app code was written for this submission; it packages the existing Pali 1.0.11 code. New headset stereo/gaze, long-content, live hit regions, hover/keyboard focus, reduced-motion and rapid animation-interruption checks were not performed. No fresh real-library mutation test was run for this packaging-only update.

## Initial release 1.0.10

**1.0.10 is live on the [App Store](https://apps.apple.com/app/id6821613011)**, released 12 October 2026 at 20:48:30 BST. Apple’s public pages and lookup data confirm version 1.0.10 and free pricing in the U.K. and U.S.; worldwide availability was configured for all 175 countries and regions. The owner reported approval, and automatic release completed.

## Release identity

| Field | Value |
| --- | --- |
| Seller | Gershom Agim |
| Team | HLW2MGYU7M |
| App Store Connect app | 6821613011 |
| Bundle | com.llucid.simplevisiongallery |
| Version and build | 1.0.10 |
| Localization / category | English (U.K.) / Photo & Video |
| Source commit | 46c1c1b1787ccbfc39d4710d15bd0c9d0713ebbd |
| Processed build ID | d5627864-1d63-4994-a9fc-b4a5479d3ccb |
| Submission ID | 824ff151-b0d6-4416-b2d2-1029a8c54e81 |

[Submission receipt](https://appstoreconnect.apple.com/apps/6821613011/distribution/reviewsubmissions/details/824ff151-b0d6-4416-b2d2-1029a8c54e81). The owner requested public source after submission; [SimpleVisionGallery](https://github.com/llucid-97/SimpleVisionGallery) is now public. The separate public website repository contains only marketing and support material.

## Package and validation

Release archive queue job `job-11222` built with Xcode 27 / visionOS 27 SDK. Official Xcode export used a cloud-managed Apple Distribution certificate and App Store provisioning profile. Deep, strict signature verification passed. Exported Info.plist has both version fields set to 1.0.10, no non-exempt encryption, and descriptive Photos permission text. The privacy manifest declares no collection or tracking and the UserDefaults required-reason API. No third-party frameworks are embedded.

Upload completed at 13:32:17 BST; the processed build was later verified and selected in App Store Connect. Four untouched native 3840 × 2160 JPEG screenshots from queue job `job-11228` show albums, grid, original-image viewer and two arranged viewers. Their visible product source matches the release commit; invisible fixture helpers supplied original generated artwork. Simulator captures do not demonstrate spatial generation or stereo appearance.

The owner approved recent on-device dogfooding. Version 1.0.10 changes public About/privacy links and a Simulator-only status label. This distribution candidate has not been installed through TestFlight on Pali; that is separate from build validation and submission.

## App Store forms

Free Apps Agreement active; no paid agreement or banking setup needed for this free app without purchases. Seller identity and private review contact verified. Owner confirmed personal hobby; non-trader status active. Category, listing, age rating 4+, content rights, no high motion, free worldwide availability and automatic release saved. Data Not Collected privacy answers published after the owner's explicit confirmation. Review notes explain Photos access, on-device spatial conversion, 2D fallback, multiple windows, album moves and batch deletion. No app sign-in required. Apple's submission checks passed.

## Product claims and limits

- Spatial viewing is on by default. Eligible ordinary photos open as generated scenes; existing spatial photos can display in spatial stereo. Unsupported or failed generation remains available in 2D.
- Scene results are temporary in-memory viewing content, not permanent conversions saved to Photos. Do not promise every image always converts.
- Users can open multiple slideshow windows, arrange two side by side and loop videos.
- Bin actions move media into an ordinary Photos album named “recycle bin”. Remove from Album only removes membership. Permanent deletion is available inside the bin with an in-app review and one native Photos confirmation per batch.

## Follow-ups

The public support website links to the live App Store listing. The 1.0.13 review heartbeat runs weekly on Sunday at 21:00 Europe/London. After approval, verify public version 1.0.13 before pausing it. Do not cancel or reupload the unchanged submission. No phone ping is requested. Pali previously received the cache changes as development version 1.0.12. Add Invite Friends using the verified live App Store link, a social page after launch and Donate after its route exists. The temporary support mailbox already has a mailto link; replace it when a dedicated mailbox is ready.
