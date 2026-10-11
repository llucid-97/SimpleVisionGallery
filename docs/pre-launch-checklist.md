<!-- Target audience: humans -->
# Simple Vision Gallery — launch checklist

Checked 11 October 2026. Goal: submit the app for review today. Going live depends on Apple approving it; same-day availability is not guaranteed. [Apple review status](https://developer.apple.com/help/app-review/after-submitting-for-review/review-status)

Gershom approved dogfood version 1.0.7. Version 1.0.8 passed Simulator checks and removes the privacy placeholder, repairs icon transparency, adds email support and fixes the side-by-side panels at inward angles rather than tracking your head. This checklist does not mean the App Store account, upload, or submission has been verified.

## Already ready

- [x] Paid developer membership and Pali signing work.
- [x] Standalone app, private repository, saved Cinema styling and semantic versioning.
- [x] Simulator tests cover real Photos moves/removals/bin batches, virtual views, playlists, search and settings. Recent device dogfooding is approved by Gershom.
- [x] In-app privacy policy and privacy manifest exist; source uses Apple frameworks, with no developer service, advertising or analytics.

## Owner choices

- [x] **Price:** Free.
- [x] **Countries:** All countries.
- [ ] **Proposed legal seller/developer:** Gershom Agim; confirm it matches the Apple Developer membership. Individual memberships use the legal name publicly. [Apple developer-name rules](https://developer.apple.com/help/app-store-connect/create-an-app-record/set-your-developer-name)
- [x] **Public support email:** [agim.gershom@gmail.com](mailto:agim.gershom@gmail.com), temporary until a dedicated mailbox is ready.

## Do first — remaining owner details

- [ ] **Seller identity and App Review contact:** verify Gershom Agim against the membership and provide the private App Review contact email and phone.
- [ ] **Public support and privacy pages:** choose hosting and publish the final privacy policy with the legal identity, effective date and contact details. Publish a public support page, and confirm both URLs work without signing in. The temporary support email is already in the app and policy draft. [Privacy requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/), [support contact requirement](https://developer.apple.com/app-store/review/guidelines/#safety)
- [ ] **Trader status:** complete the status declaration shown in App Store Connect. If distributing as a trader in the EU, complete Apple's contact verification. Apple publishes trader address, phone and email on the EU listing; individuals may use a verified P.O. Box for that public address. A free download alone does not decide trader status. [Apple's trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)

## Finish the release package — Codex, with owner checks

- [ ] **Public-facing About links:** the current GitHub and Known Issues links require private-repository access. Replace them with public support/issue destinations, or hide them for launch. The source repository can stay private.
- [x] **Privacy cleanup:** the in-app privacy policy no longer shows “Before Public Release”; native UI validation passed.
- [ ] **Headset visual check:** verify the repaired icon in the system app launcher and look around paired spatial scenes. Their inward angles are fixed to the window; exact initial head alignment is approximated. Simulator checks passed for native surface visibility and fixed orientation.
- [ ] **Listing:** approve name, subtitle, description, keywords and category using the existing listing draft. Describe automatic spatial viewing and multiple windows; avoid claiming every photo always converts or that conversions are permanent.
- [ ] **Screenshots:** prepare Apple Vision Pro screenshots at **3840 × 2160**, showing the gallery, a spatial viewer and two viewers together. Use owned or licensed demo media and remove personal information. An app preview video is optional. [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications?page_id=52545)
- [ ] **App record and forms:** verify App Store Connect access, register/select the exact bundle ID `com.llucid.simplevisiongallery`, create the visionOS app record, and complete age rating, content rights, App Privacy and export-compliance fields. “Data Not Collected” is the expected privacy answer from the inspected source; confirm it against the final archive and included SDKs.
- [ ] **Distribution build:** archive the final latest-main candidate in **Release**, use App Store distribution signing, validate and upload it, then wait for processing. The current paid development install on Pali is not an App Store upload. Keep both Apple version fields equal to the semantic version. Xcode 27 / visionOS 27 SDK meets the currently published upload minimum; the newer minimum starts April 2027. [Current minimum](https://developer.apple.com/news/?id=ueeok6yw), [Apple submission guidance](https://developer.apple.com/app-store/submitting/)
- [ ] **Final candidate smoke test:** preferably install the uploaded candidate through internal TestFlight on Pali. Check first launch with full, limited and denied Photos access; ordinary/spatial photos and videos; two viewers; move/remove/bin; portrait content; looping and settings persistence. Use generated fixtures for permanent deletion. Reuse existing test evidence where the code has not changed.
- [ ] **Review handoff:** provide review notes explaining Photos access, on-device conversion and its 2D fallback, multiple windows, the bin's album-based behavior and one native confirmation per permanent-delete batch. No app account or login is needed. Select the processed build, verify all required fields are complete, choose automatic release after approval or manual release, then submit for App Review. [Submission flow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/)

## Can wait until after launch

Dedicated mailbox to replace the temporary email; social page; Invite Friends after an App Store URL exists; Donate after its payment route is set up; macOS support; permanent spatial-scene caching. These do not need to delay the first release.

## Current gaps

App Store Connect access, app record, seller identity, App Review phone, trader declaration, public page hosting, distribution signing/upload and submission are **not yet verified**. Free pricing, all-country availability and the temporary public support email are decided. Existing support/privacy documents and listing are drafts.
