#!/usr/bin/env python3
"""Audience: agents. Check that viewer destinations don't fetch media counts."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def unique_slice(text, start_marker, end_marker):
    if text.count(start_marker) != 1 or text.count(end_marker) != 1:
        raise RuntimeError(f"Expected unique markers: {start_marker!r}, {end_marker!r}")
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, help='Repository root or source fixture')
    args = parser.parse_args()
    repo = args.repo.resolve() if args.repo else Path(__file__).resolve().parents[1]
    gallery = repo / 'SimpleVisionGallery/Gallery'
    manager = (gallery / 'GalleryManager.swift').read_text()
    store = (gallery / 'GalleryViewerStore.swift').read_text()
    album = unique_slice(manager, 'struct GalleryAlbum: Identifiable, Hashable {',
                         '\nstruct GalleryToast:')
    refresh = unique_slice(store, '    func refreshAlbums() async {',
                           '\n    func updateAlbumTitle(')
    construction = unique_slice(refresh, 'result.append(GalleryAlbum(',
                                '            if index.isMultiple(of: 128) {').strip()
    source = '''
import Foundation
final class PHAssetCollection {
    let localIdentifier: String
    let localizedTitle: String?
    init(id: String, title: String?) { localIdentifier = id; localizedTitle = title }
}
enum GalleryRecycleBin { static func isRecycleBin(_ album: GalleryAlbum) -> Bool { false } }
final class PHFetchOptions { var predicate: NSPredicate? }
enum PHAssetMediaType: Int { case image = 1, video = 2 }
struct GalleryVirtualScope: Hashable {}
struct FetchResult { let count: Int }
final class PHAsset {
    static var countQueries = 0
    static func fetchAssets(in collection: PHAssetCollection, options: PHFetchOptions?) -> FetchResult {
        countQueries += 1
        return FetchResult(count: 7)
    }
}
''' + album + '''
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \\(message)\\n", stderr); exit(1) }
}
let collection = PHAssetCollection(id: "fixture-id", title: "Fixture album")
let control = GalleryAlbum(id: collection.localIdentifier, title: collection.localizedTitle!,
                           assetCount: 0, collection: collection, coverAsset: nil)
check(PHAsset.countQueries == 2, "control initializer must query both media types")
check(control.photoCount == 7 && control.videoCount == 7, "control counts must be real")
PHAsset.countQueries = 0
var result: [GalleryAlbum] = []
''' + construction + '''
check(PHAsset.countQueries == 0, "viewer destination unexpectedly queried media counts: \\(PHAsset.countQueries)")
check(result.count == 1, "destination must be appended")
check(result[0].id == "fixture-id" && result[0].title == "Fixture album", "destination identity and title")
check(result[0].collection === collection, "destination must retain its PhotoKit collection")
print("PASS: viewer destination avoids media-count queries and preserves identity")
'''
    with tempfile.TemporaryDirectory(prefix='gallery-refresh-check-') as tmp:
        swift = Path(tmp) / 'check.swift'
        executable = Path(tmp) / 'check'
        swift.write_text(source)
        subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                        str(swift), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    main()
