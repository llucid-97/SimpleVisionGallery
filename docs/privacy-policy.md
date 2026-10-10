<!-- Target audience: humans -->
# Privacy policy draft — Simple Vision Gallery

**Draft for owner review.** The developer identity, effective date, public support contact, and public URL are pending.

**Developer:** [PENDING — legal developer or seller name]

**Effective date:** [PENDING]

## Photos, videos, and albums

Simple Vision Gallery uses [Apple PhotoKit](https://developer.apple.com/documentation/PhotoKit) to display the albums and photos and videos you allow it to access. It asks for read and write access so it can browse your albums, create destination albums, and move selected items between albums. You can review or change Photos access in visionOS Settings.

When you open media, the app processes it on your device. Eligible ordinary photos open as generated 3D spatial scenes by default. Existing spatial photos can be shown in spatial stereo. Other photos remain available in 2D if scene generation is unsupported or fails. Scenes are generated in memory for viewing; the app does not save a permanent converted copy to Photos. Videos play in the viewer, with an optional looping setting.

The viewer’s Recycle Bin action immediately moves an item out of its current album and into an ordinary Photos album named “recycle bin.” It does not delete the photo or video from your Photos library. Grid removal also moves selected items to the recycle-bin album. Permanent deletion is available only inside that album; Photos asks for confirmation, and grid batches also have one in-app review. Photos may place deleted items in Recently Deleted. If iCloud Photos is enabled, changes to the library may sync through Apple’s service.

PhotoKit can retrieve assets stored on the device or in iCloud Photos. If an original is stored in iCloud, Apple’s Photos service may download it when Gallery requests it. See [PhotoKit](https://developer.apple.com/documentation/PhotoKit) and Apple’s [Photos privacy guidance](https://developer.apple.com/documentation/PhotoKit/delivering-an-enhanced-privacy-experience-in-your-photos-app).

## Information collection and sharing

Gallery processes photo and video content on your device and does not send it to the app developer. The app does not use analytics, advertising, tracking, or an app-operated network service. Apple’s Photos and iCloud services may retrieve or sync library content according to your settings and Apple’s terms.

The app stores preferences such as album sorting, thumbnail size, spatial lookahead, and video looping in app-local settings. It does not send these preferences to the developer.

## Your choices

You can change Photos access in visionOS Settings. You can turn off looping with the viewer’s loop button and set the spatial lookahead to zero in Gallery Settings. Removing the app removes its app-local preferences. Photos changes follow the behavior of your Photos library and iCloud settings.

## Contact

Questions or privacy requests: [PENDING — public support email or contact URL]

## Changes to this policy

This policy will be updated if the app’s data practices change.
