#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-D261CB08-8622-4D0B-9232-EF2D9738C811}"
OUT="${2:-$ROOT/workspaces/design-overhaul/round-01}"
DERIVED="${CAPTURE_DERIVED:-$ROOT/workspaces/design-overhaul/DerivedData-capture}"
BUNDLE="${CAPTURE_BUNDLE_ID:-com.llucid.simplevisiongallery.capture}"
APP="$DERIVED/Build/Products/Debug-xrsimulator/SimpleVisionGallery.app"
if [[ -e "$OUT/manifest.json" || -d "$OUT/screenshots" ]]; then
  echo "Refusing to overwrite existing capture output: $OUT" >&2
  exit 2
fi
mkdir -p "$OUT/screenshots"
python3 - "$ROOT" "$OUT" <<'PYSOURCE'
import hashlib, json, pathlib, shutil, subprocess, sys
root, out = map(pathlib.Path, sys.argv[1:])
paths = sorted(list((root / 'SimpleVisionGallery').rglob('*.swift')) + list((root / 'SimpleVisionGallery').rglob('*.metal')) + [root / 'project.yml', root / 'SimpleVisionGallery.xcodeproj/project.pbxproj'] + list((root / 'scripts').glob('*.sh')) + list((root / 'scripts').glob('*.py')))
hashes = {}
for path in paths:
    relative = path.relative_to(root)
    destination = out / 'source' / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, destination)
    hashes[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
patch = subprocess.check_output(['git', '-C', str(root), 'diff', '--binary'])
(out / 'source.patch').write_bytes(patch)
info = dict(commit=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(), files=hashes,
            source_sha256=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest(),
            tracked_diff_sha256=hashlib.sha256(patch).hexdigest())
(out / 'source-info.json').write_text(json.dumps(info,indent=2)+'\n')
PYSOURCE
if [[ "${CAPTURE_SKIP_BUILD:-0}" != 1 ]]; then
xcodebuild -project "$ROOT/SimpleVisionGallery.xcodeproj" -scheme SimpleVisionGallery \
  -destination "platform=visionOS Simulator,id=$DEVICE" -configuration Debug \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build
cp "$OUT/source-info.json" "$DERIVED/capture-build-source.json"
fi
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
# Licensed fixture files stay outside the product tree and are added only to this Debug app.
FIXTURES="${CAPTURE_FIXTURES:-$ROOT/.codex-tests/design-fixtures-mixed}"
python3 "$ROOT/scripts/prepare_capture_photos.py" "$FIXTURES"
cp "$FIXTURES"/capture-*.jpg "$APP/"
cp "$FIXTURES/capture-fixtures.json" "$APP/"
cp "$FIXTURES/capture-fixtures.json" "$OUT/"
xcrun simctl install "$DEVICE" "$APP"
read -r -a ids <<< "${CAPTURE_SURFACES:-albums photos recycle-bin album-detail loading empty error rename move delete-confirmation vault-confirmation selection toast settings vault about menus overflow-menu sort-menu filter-menu visibility-menu selection-menu album-actions-menu native-viewer native-viewer-pair viewer-more-menu privacy licenses about-faq-expanded thumbnail-size-popover album-delete album-delete-recovery theme}"
for id in "${ids[@]}"; do
  xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE" "$BUNDLE" -gallery-capture-surface "$id"
  sleep "${CAPTURE_SETTLE_SECONDS:-3}"
  xcrun simctl io "$DEVICE" screenshot "$OUT/screenshots/$id.png" >/dev/null
  sips -g pixelWidth -g pixelHeight "$OUT/screenshots/$id.png" | awk '/pixelWidth|pixelHeight/ {printf "%s%s", sep, $2; sep=","} END {print ""}' > "$OUT/screenshots/$id.dimensions"
done
python3 "$ROOT/scripts/capture_manifest.py" "$ROOT" "$OUT" "$DEVICE" "$DERIVED"
