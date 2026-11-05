#!/usr/bin/env python3
"""Target audience: agents. Inventory every capture and distinguish fixtures from runtime proof."""
import json
from pathlib import Path
import subprocess
import sys

root, out, device, derived = sys.argv[1:]
out = Path(out)
built_path = Path(derived) / 'capture-build-source.json'
built = json.loads(built_path.read_text()) if built_path.exists() else None
catalog = {
    'albums': ('shared-component', 'Selected production-default D GalleryCinemaDesign with six per-scene synthetic album subsets and native ornaments'),
    'albums-classic': ('shared-component-debug-fallback', 'Explicit Debug R sidebar fallback with the same six covers'),
    'photos-classic': ('shared-shell-debug-fallback', 'Explicit Debug R sidebar fallback with shared20 records'),
    'photos': ('shared-shell', 'GalleryCinemaDesign album room, bounded square cells and the shared20 mixed records'),
    'photos-ornaments': ('shared-shell-prototype', 'Native external labelled navigation and compact real-toolbar adapter; shared240pt grid and20 records; R fallback retained'),
    'albums-ornaments': ('shared-shell-prototype', 'Same native external navigation and compact album search/Sort/Select/Filter/More toolbar; six shared album covers in three columns; real production callbacks, inert capture callbacks'),
    'photos-scrolled': ('shared-shell', 'Same shared20 grid with bottom initial scroll anchor'),
    'album-detail': ('shared-shell', 'GalleryCinemaDesign synthetic album showing all shared sample records'),
    'recycle-bin': ('shared-shell', 'Synthetic recycle-bin scope; no recycle service or deletion'),
    'selection': ('shared-shell', 'Three synthetic selected-cell badges; no production gesture or mutation'),
    'loading': ('shared-component', 'GalleryCinemaDesign loading state'),
    'empty': ('mock', 'Synthetic empty content in the production shell'),
    'error': ('mock', 'Synthetic error content in the production shell'),
    'toast': ('shared-component', 'GalleryToastBanner on the production shell'),
    'settings': ('shared-component', 'GallerySettingsView, local capture-only manager'),
    'vault': ('shared-component', 'GalleryVaultView in the dedicated simulator current locked state'),
    'about': ('shared-component', 'GalleryAboutView'),
    'about-faq-expanded': ('shared-component', 'GalleryAboutView with the first actual FAQ expanded'),
    'privacy': ('shared-component', 'GalleryPrivacyView'),
    'licenses': ('shared-component', 'GalleryLicensesView'),
    'rename': ('shared-component', 'GalleryRenameAlbumSheet with a synthetic album'),
    'move': ('shared-component', 'GalleryMoveSheet with no real destinations or selected assets'),
    'thumbnail-size-popover': ('shared-component', 'Production GalleryThumbnailSizePopover content, presented as a fixture sheet'),
    'album-delete': ('shared-component', 'GalleryAlbumDeletionSheet with four synthetic Photos IDs; hit testing disabled'),
    'album-delete-recovery': ('shared-component', 'Same production sheet in recovery-review mode; fake plan and hit testing disabled'),
    'delete-confirmation': ('mock-native-alert', 'Native alert presentation with inert synthetic confirmation'),
    'vault-confirmation': ('mock-native-alert', 'Native alert presentation with inert synthetic vault confirmation'),
    'native-viewer': ('native-component-fixture', 'GalleryRealityImage/ImagePresentationComponent.mono, production plain window/header/control material and540pt depth/160pt clearance/52pt gaps'),
    'native-viewer-pair': ('native-component-fixture', 'Two mono surfaces with the production paired widths and inward±10° angles'),
    'native-viewer-portrait': ('native-component-fixture', 'Mono portrait fixture using production aspect-based window height budget'),
    'native-viewer-pair-portrait': ('native-component-fixture', 'Two copies of the same portrait mono fixture at production paired widths/angles and aspect-based clearance; not mixed-aspect sessions'),
    'viewer-more-menu': ('mock-native-popover', 'Native popover with inert action rows; raised image hidden as in production, bounded flat preview softly blurred/dimmed underneath'),
    'ornament-overflow-menu': ('mock-expanded-menu', 'Shared mock overflow rows and native glass over selected-default D Albums ornaments; not an OS-opened menu or action proof'),
    'native-viewer-last-light': ('native-component-fixture-parent-only', 'Supplemental native Last Light sunburst fixture for parent comparison; exclude from the unchanged primary Coastal three-task cohort'),
    'theme': ('shared-component', 'Reusable native theme sample widgets; exclude from theme-blind judging'),
}
catalog['viewer'] = catalog['native-viewer']
for name in ['menus','overflow-menu','sort-menu','filter-menu','visibility-menu','selection-menu','album-actions-menu']:
    catalog[name] = ('mock-expanded-menu', 'Per-menu mock rows over production shell; local material blur only, no invented global blur; actions inert')
blocked = {
    'photo-library-viewer': 'Requires a real PHAsset-backed viewer session; bundled mono components are separate evidence.',
    'photo-library-paired-viewer': 'Requires real PHAsset-backed sessions; bundled mono pairs are separate evidence.',
    'real-rename': 'Requires a real editable Photos album and user-authorized mutation.',
    'real-move': 'Requires actual assets/destination albums; not invoked by synthetic capture.',
    'real-delete': 'Requires an actual deletion review; not invoked by synthetic capture.',
    'real-vault-transfer': 'Would authenticate/write encrypted media/request Photos deletion; not invoked.',
    'system-share-sheet': 'Requires actual selected media/system interaction; not invoked.',
    'system-color-picker': 'Actual ColorPicker control shown in Settings; system picker popover not opened.',
    'system-permission-dialog': 'Capture routes intentionally avoid Photos authorization.',
    'vault-unlocked-and-progress': 'Requires authentication and real vault state/operation; locked page only is rendered.',
    'vault-pending-original-removal': 'Requires verified copied-awaiting-deletion records; no real operation triggered.',
    'vault-unreadable-cleanup-note': 'Requires interrupted/corrupt recovery state; no vault data altered for visuals.',
    'vault-cleanup-finish-confirmation': 'Requires a committed interrupted album deletion; source contract preserved, not triggered.',
    'vault-discard-recovery-confirmation': 'Requires an unreadable recovery note; no real note fabricated in storage.',
    'vault-discard-saved-copies-confirmation': 'Requires pending vault copies; not created for visuals.',
    'vault-restore-missing-albums-confirmation': 'Requires failed restore state; not triggered.',
    'native-video-and-generated-spatial': 'No video/spatial-generation or hardware claim from mono JPEG fixtures.',
    'apple-photos-albums-and-viewer': 'Native Photos library baseline captured separately; album/viewer references remain separately qualified.',
    'apple-photos-scrolled-and-menu': 'No native Photos scroll/menu automation result; no pass inferred.',
}
records = []
for image in sorted((out / 'screenshots').glob('*.png')):
    name = image.stem
    base = name.replace('-reduced-transparency','').replace('-reduced-motion','').replace('-accessibility','')
    kind, evidence = catalog.get(base, ('unknown', 'Unknown capture route; inspect before any claim.'))
    dimensions = subprocess.check_output(['sips','-g','pixelWidth','-g','pixelHeight',str(image)],text=True).splitlines()
    records.append(dict(id=name, rendering=kind, evidence=evidence, captured=True, visual_status='unreviewed',
        dimensions=dict(width=int(dimensions[-2].split()[-1]),height=int(dimensions[-1].split()[-1])),
        screenshot='screenshots/'+image.name,
        reduced_transparency='-reduced-transparency' in name, reduced_motion='-reduced-motion' in name,
        limits='Synthetic/bundled fixtures do not establish PhotoKit sessions, gestures, motion, performance or hardware comfort.'))
for name, reason in blocked.items():
    records.append(dict(id=name,rendering='not-captured',captured=False,blocked_status=reason))
fixture_path = out / 'capture-fixtures.json'
manifest = dict(build_source=built, device_udid=device,
    source_commit=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip(),
    fixture=json.loads(fixture_path.read_text()) if fixture_path.exists() else None,
    thumbnail_size_points=240, thumbnail_size_note='Shared production adaptive layout;240pt is the new-install default. Existing saved user sizes remain in force.',
    accessibility_preview_note='Accessibility suffix forces actual SwiftUI accessibility1 type to exercise the R layout fallback. Reduced variants force shared component fallbacks. OS accessibility settings/materials are unchanged; still images cannot prove motion behavior.', 
    surfaces=records)
(out / 'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
