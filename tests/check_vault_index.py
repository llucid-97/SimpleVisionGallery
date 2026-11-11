# Target audience: agents
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'SimpleVisionGallery/Gallery/GalleryManager.swift').read_text()
s=s[s.index('nonisolated struct GalleryVaultIndex: Sendable {'):s.index('/// Coalesces Photos notifications')]
a=s.index('    static func fromPhotoLibrary('); b=s.index('{',a)+1; depth=1
while depth:
 depth += (s[b]=='{')-(s[b]=='}'); b+=1
s=s.replace("@MainActor func", "func")
s=s[:a]+"    static func fromPhotoLibrary(records: [GalleryVaultRecord], excludedIDs: Set<UUID> = []) -> GalleryVaultIndex { GalleryVaultIndex(records: records, excludedIDs: excludedIDs) }\n"+s[b:]
stubs='''import Foundation
nonisolated enum PHAssetMediaType: Int { case image = 1, video = 2 }
nonisolated enum GalleryVirtualScope: String { case photos, unfiled, recycleBin; var virtualID: String { rawValue } }
nonisolated enum GalleryMediaFilter { case all, photos, videos }
nonisolated enum GalleryAssetSortMode { case photosOrder, name, date, random }
struct GalleryAlbum { let id: String; let title: String; var collection: String? = nil; var virtualScope: GalleryVirtualScope? = nil; var assetCount = 0 }
nonisolated enum GalleryRecycleBin { static func isRecycleBinTitle(_ title: String) -> Bool { title.lowercased() == "recycle bin" } }
'''
checks=r'''
func record(_ albums: [GalleryVaultAlbum]) -> GalleryVaultRecord {
 GalleryVaultRecord(id: UUID(), sourceIdentifier: UUID().uuidString, filename: "fixture.jpg", mediaType: 1, mediaSubtypes: 0, pixelWidth: 16, pixelHeight: 16, duration: 0, creationDate: nil, modificationDate: nil, latitude: nil, longitude: nil, isFavorite: false, albums: albums, resources: [], state: .privateItem, restoredIdentifier: nil)
}
let parent = GalleryVaultAlbum(id: "parent", title: "Parent", position: 4)
let hidden = GalleryVaultAlbum(id: "only-binned", title: "Only binned", position: 8)
let filed = record([parent]), unfiled = record([]), binned = record([parent, GalleryVaultRecycleBin.album]), binnedOnly = record([hidden, GalleryVaultRecycleBin.album])
var index = GalleryVaultIndex(records: [filed, unfiled, binned, binnedOnly])
let ids = { (records: [GalleryVaultRecord]) in Set(records.map(\.id)) }
precondition(ids(index.all) == [filed.id, unfiled.id] && ids(index.unfiled) == [unfiled.id])
precondition(ids(index.byAlbum[parent.id]!) == [filed.id] && index.byAlbum[hidden.id] == nil && index.albumTitles[hidden.id] == nil)
for scope in [GalleryVirtualScope.photos, .unfiled] {
 let rows = index.records(for: GalleryAlbum(id: scope.virtualID, title: scope.rawValue, virtualScope: scope), filter: .all, search: "")
 precondition(!rows.contains { GalleryVaultRecycleBin.contains($0) })
}
precondition(index.records(for: GalleryAlbum(id: hidden.id, title: hidden.title), filter: .all, search: "").isEmpty)
let bin = GalleryAlbum(id: "bin", title: "Recycle Bin", virtualScope: .recycleBin)
precondition(ids(index.records(for: bin, filter: .all, search: "")) == [binned.id, binnedOnly.id])
precondition(ids(index.records(for: GalleryAlbum(id: "photos-bin", title: "Recycle Bin"), filter: .all, search: "")) == [binned.id, binnedOnly.id])
precondition(index.counts(for: GalleryVirtualScope.photos.virtualID).photos == 2 && index.counts(for: parent.id).photos == 1 && index.counts(for: hidden.id).photos == 0)
precondition(index.recycleBinCounts.photos == 2)
precondition(index.containsOnlyBinnedItems(in: GalleryAlbum(id: hidden.id, title: hidden.title, collection: "collection")))
precondition(index.excludeRestored(binned.id) && index.recycleBinCounts.photos == 1 && index.counts(for: GalleryVirtualScope.recycleBin.virtualID).photos == 1)
precondition(ids(index.records(for: bin, filter: .all, search: "")) == [binnedOnly.id])
let locked = GalleryVaultIndex()
precondition(locked.all.isEmpty && locked.recycleBin.isEmpty && locked.albumTitles.isEmpty && locked.binnedAlbumIDs.isEmpty && locked.recycleBinCounts.photos == 0)

let input = (0..<1000).map { i -> GalleryVaultRecord in
 var row = record(i % 3 == 0 ? [] : [GalleryVaultAlbum(id: parent.id, title: parent.title, position: i % 17)])
 row.filename = "generated-\(1000-i).jpg"
 row.creationDate = Date(timeIntervalSince1970: Double(i % 31))
 return row
}
let before = GalleryVaultIndex(records: input)
var changed = input
for i in [1, 9, 24, 63] { changed[i].albums.append(GalleryVaultRecycleBin.album) }
changed.remove(at: 86)
let after = GalleryVaultIndex(records: changed)
let updatedIDs = Set([1,9,24,63,86].map { input[$0].id })
var incremental = before
incremental.applyMutationChanges(updatedIDs, records: changed.filter { updatedIDs.contains($0.id) })
precondition(incremental.albumTitles == after.albumTitles && incremental.binnedAlbumIDs == after.binnedAlbumIDs)
for id in ["photos", "unfiled", "recycleBin", parent.id] {
 precondition(incremental.counts(for: id).photos == after.counts(for: id).photos)
 precondition(incremental.counts(for: id).videos == after.counts(for: id).videos)
 precondition(incremental.privateItemCounts[id, default: 0] == after.privateItemCounts[id, default: 0])
}
let albums = [GalleryAlbum(id: "all", title: "Photos", virtualScope: .photos), GalleryAlbum(id: parent.id, title: parent.title), GalleryAlbum(id: "unfiled", title: "Unfiled", virtualScope: .unfiled), bin]
for album in albums {
 for sort: GalleryAssetSortMode in [.photosOrder, .name, .date, .random] {
  for ascending in [true, false] {
   for filter: GalleryMediaFilter in [.all, .photos, .videos] {
    for search in ["", "generated-9"] {
     let seed = UUID()
     let old = before.records(for: album, filter: filter, search: search, sort: sort, ascending: ascending, shuffleSeed: seed)
     let expected = after.records(for: album, filter: filter, search: search, sort: sort, ascending: ascending, shuffleSeed: seed)
     let actual = incremental.records(for: album, filter: filter, search: search, sort: sort, ascending: ascending, shuffleSeed: seed, preservingOrderOf: old, changedIDs: updatedIDs)
     precondition(actual == expected)
    }
   }
  }
 }
}
let restoredInput = input.filter { $0.id != input[86].id }
let restoredIndex = GalleryVaultIndex(records: restoredInput)
incremental.applyMutationChanges(updatedIDs, records: restoredInput.filter { updatedIDs.contains($0.id) })
for album in albums {
 for sort: GalleryAssetSortMode in [.photosOrder, .name, .date, .random] {
  let seed = UUID()
  let old = after.records(for: album, filter: .all, search: "", sort: sort, shuffleSeed: seed)
  let actual = incremental.records(for: album, filter: .all, search: "", sort: sort, shuffleSeed: seed, preservingOrderOf: old, changedIDs: updatedIDs)
  let expected = restoredIndex.records(for: album, filter: .all, search: "", sort: sort, shuffleSeed: seed)
  precondition(actual == expected)
 }
}
precondition(incremental.recycleBinCounts.photos == 0 && incremental.binnedAlbumIDs.isEmpty)
print("PASS incremental recycle, permanent removal, Put Back counts, bin-only parents and sorted merging")
print("PASS queued publication order reuse equals a full rebuild for all scopes, sorts, directions, filters and searches, including bin additions")
print("PASS production index excludes bin records from all, unfiled, parents, titles and counts; bin-only albums hide; restore and locked counts clear")
'''
with tempfile.TemporaryDirectory(prefix='vault-bin-index-') as tmp:
 p=Path(tmp); unit=p/'main.swift'; unit.write_text(stubs+s+checks)
 subprocess.run(['swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'SimpleVisionGallery/Gallery/GalleryVaultModels.swift'),str(unit),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
