<!-- Target audience: humans -->
# Privacy policy — Simple Vision Gallery

**Developer:** Gershom Agim

**Effective date:** 11 October 2026

**Public policy:** https://llucid-97.github.io/simple-vision-gallery/privacy.html

## Photos, videos, and albums

Simple Vision Gallery uses [Apple PhotoKit](https://developer.apple.com/documentation/PhotoKit) to display the albums and photos and videos you allow it to access. It asks for read and write access so it can browse your albums, create destination albums, and move selected items between albums. You can review or change Photos access in visionOS Settings.

When you open media, the app processes it on your device. Eligible ordinary photos open as generated 3D spatial scenes by default. Existing spatial photos can be shown in spatial stereo. Other photos remain available in 2D if scene generation is unsupported or fails. Scenes are generated in memory for viewing; the app does not save a permanent converted copy to Photos. Videos play in the viewer, with an optional looping setting.

The viewer’s Recycle Bin action immediately moves an item out of its current album and into an ordinary Photos album named “recycle bin.” It does not delete the photo or video from your Photos library. Grid removal also moves selected items to the recycle-bin album. Permanent deletion is available only inside that album; Photos asks for confirmation, and grid batches also have one in-app review. Photos may place deleted items in Recently Deleted. If iCloud Photos is enabled, changes to the library may sync through Apple’s service.

PhotoKit can retrieve assets stored on the device or in iCloud Photos. If an original is stored in iCloud, Apple’s Photos service may download it when Gallery requests it. See [PhotoKit](https://developer.apple.com/documentation/PhotoKit) and Apple’s [Photos privacy guidance](https://developer.apple.com/documentation/PhotoKit/delivering-an-enhanced-privacy-experience-in-your-photos-app).

## Private Vault

Private Vault stores media and its recorded parent album information encrypted inside the app on this device. Device authentication unlocks access for the app session. Switching apps does not lock the vault. It locks when you choose Lock or when the device’s protected data becomes unavailable, including when the device locks. Private items then appear in Gallery’s lists and slideshows; locking clears those presentations and temporary viewing files. Gallery reports a cleanup failure and refuses another unlock until temporary files can be cleared.

Moving to the vault saves and verifies copies before asking Photos to delete originals. For a batch, one deletion request covers only the successfully saved items. Deletion may sync to other devices through iCloud Photos, and Recently Deleted can retain originals and their storage space. Edited photos and non-Live videos are saved as originals only. Their edits are discarded once they leave Photos; result counts say how many. Unedited items retain all resources, including Live Photo pairs. Edited Live Photos, missing or multiple originals, other unsupported items and unfinished copies stay in Photos.

The vault does not sync or have a backup. Deleting the app, losing this device, or removing the device passcode can make private items unrecoverable. Restore important items to Photos before doing any of these. Restoring creates new Photos items; exact original identifiers, editing history and order in every album are not guaranteed. A missing or non-editable parent album requires an explicit choice before restoration can omit that album.

Private media and vault keys are not sent to the developer. Vault metadata, including original filenames and album names, is encrypted on disk. Existing album names in the Photos library remain unchanged.

## Information collection and sharing

Gallery processes photo and video content on your device and does not send it to the app developer. The app does not use analytics, advertising, tracking, or an app-operated network service. Apple’s Photos and iCloud services may retrieve or sync library content according to your settings and Apple’s terms.

The app stores preferences such as album sorting, thumbnail size, spatial lookahead, and video looping in app-local settings. It does not send these preferences to the developer.

## Your choices

You can change Photos access in visionOS Settings. You can turn off looping with the viewer’s loop button and set the spatial lookahead to zero in Gallery Settings. Removing the app removes its app-local preferences and local vault files. Restore private media to Photos first. Photos changes follow the behavior of your Photos library and iCloud settings.

## Contact

Questions or privacy requests: [agim.gershom@gmail.com](mailto:agim.gershom@gmail.com).

If you email support, Gershom receives the information you include in your message and uses it to respond.

## Changes to this policy

This policy will be updated if the app’s data practices change.
