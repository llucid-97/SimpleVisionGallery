<!-- Target audience: humans -->
# App Store release checklist

Status: groundwork only. Apple Developer Program enrollment is pending. Revisit enrollment status and pricing next week. No App Store Connect changes, purchases, uploads, or submissions have been made as part of this preparation.

## Release checklist

- [ ] Check the enrollment result next week. Once the membership is active, use an App Store Connect role with the permissions needed for the chosen release work. The Account Holder handles membership agreements; paid apps and in-app purchases require the Paid Apps Agreement. See [App Store Connect workflow](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow/) and [agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/).
- [ ] Decide pricing and availability next week. Confirm the seller name and public support contact/URL. The public privacy-policy URL also remains to be hosted and entered; Apple requires a privacy policy URL for App Store apps. See [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/).
- [ ] Review the final target’s permission text, privacy manifest, included SDKs, privacy answers, and listing against the shipped features. The populated target uses PhotoKit for library changes and requests cloud originals through PhotoKit when needed.
- [ ] Human-review the original three-layer visionOS app icon now in the asset catalog. Apple specifies a square 1024 × 1024 icon with two or three unmasked layers; Xcode composes the layers into the circular icon. Keep the main subject centered and avoid a hole-like shape in the background. See [visionOS app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons) and [Xcode image-stack setup](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).
- [ ] Validate spatial scene generation on Apple Vision Pro. The visionOS Simulator cannot generate `Spatial3DImage`; it can still help check layout and ordinary viewer behavior. Capture truthful product screenshots from the running app. Apple currently requires Apple Vision Pro screenshots at 3840 × 2160 pixels. See [Spatial3DImage overview](https://developer.apple.com/documentation/realitykit/imagepresentationcomponent/spatial3dimage) and [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
- [ ] Complete the age-rating questionnaire, content-rights answers and accessibility details in App Store Connect. Describe only support tested in the app. See Apple’s [submission checklist](https://developer.apple.com/app-store/submitting/).
- [ ] At release preparation, check Apple’s then-current upload SDK requirement. Apple lists the visionOS 27 SDK requirement starting April 2027; that future date does not set the present October 2026 requirement. See [Submitting apps](https://developer.apple.com/app-store/submitting/).
- [ ] When enrollment and the release choices are settled, create or complete the App Store Connect app record, enter the metadata, select the build, and submit the chosen release for review. Apple’s [submission flow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/) describes the required metadata and build selection.

## Product claims and limits

- Spatial viewing is on by default. Eligible ordinary photos open as generated spatial scenes; existing spatial photos can display in spatial stereo. Supported photos can fall back to 2D if spatial generation is unavailable or fails.
- Apple’s `Spatial3DImage.generate()` requires at least 320 pixels on the shortest side, no more than 16,384 pixels on the longest side, and an aspect ratio from 1:3 through 3:1. Generation can take a few seconds. See Apple’s [generation limits](https://developer.apple.com/documentation/realitykit/imagepresentationcomponent/spatial3dimage/generate()).
- Users can open multiple slideshow windows and arrange two side by side. Videos play in the viewer and can be set to loop.
- The viewer’s Recycle Bin moves media into an ordinary Photos album called “recycle bin”; it does not delete media from the library. The grid’s Delete from Library action is separate and asks Gallery and Photos to confirm the selected deletion.
- Generated spatial scenes are temporary in-memory viewing content. Do not claim permanent conversion or bulk conversion.

## Pending publication details

- Public seller/developer identity and support contact/URL
- Public privacy-policy URL
- Price and storefront availability
- Human icon review and real Apple Vision Pro screenshots
