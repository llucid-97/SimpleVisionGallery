<!-- Target audience: humans -->
# Simple Vision Gallery

Your photos in space, automatically.

A standalone gallery for Apple Vision Pro. Open a supported photo and it becomes a spatial scene without pressing a conversion button. Open several photos or videos at once, or arrange two slideshows side by side.

- Browse Photos albums, including large libraries, with paged media grids.
- Swipe through the album in its current order.
- Prepare upcoming items ahead of time; the spatial prefetch window defaults to three.
- Show ordinary videos in 2D and spatial videos with their native depth.
- Toggle a photo's spatial view, move items between albums, or send them to a recycle-bin album.
- Keep a persistent video-loop setting.
- Resize windows vertically while their width stays fixed.

Spatial scenes are viewing experiences generated on the headset. Photos that Apple's scene API cannot convert show their original image. Scene preparation is bounded and in memory; this app does not scan and convert your entire library at launch or create permanent converted files.

## Build

Requires Xcode 27 and visionOS 26.1 or later. The project is checked in; XcodeGen is only needed after changing `project.yml`.

```sh
xcodebuild -project SimpleVisionGallery.xcodeproj -scheme SimpleVisionGallery \
  -destination 'generic/platform=visionOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

For a signed headset build, select your Apple Developer team in Xcode's Signing & Capabilities tab. The bundle identifier is currently `com.llucid.simplevisiongallery`; finalize it with the release team before App Store registration.

The simulator uses native image and video components with mono fixtures. Generated spatial scenes and stereo appearance need a headset check.

## App Store

Developer Program enrollment is pending. See [the release checklist](docs/app-store-release.md), [listing draft](docs/app-store-listing.md), and [privacy policy draft](docs/privacy-policy.md). Public URLs, account/team, final icon review, pricing and distribution signing must be settled before submission.

## Origin

Extracted from the working PhotoKit Gallery in [SimpleVisionTools](https://github.com/llucid-97/SimpleVisionTools) at `bbb285c70f53f0d852165cd59bf4829a69a59a49`. This repository contains the native gallery and its shared design helpers. There is no embedded Python runtime or unrelated toolbox code.
