import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
@main struct Check {
 static func main() async throws {
  func setup() -> (PHAssetCollection, PHAssetCollection, PHAssetCollection) {
   FakePhotoLibrary.reset()
   let source = PHAssetCollection("source", "Source"), dest = PHAssetCollection("dest", "Destination"), other = PHAssetCollection("other", "Other")
   FakePhotoLibrary.collections = ["source": source, "dest": dest, "other": other]
   for id in ["target", "unrelated"] { FakePhotoLibrary.assets[id] = PHAsset(id); source.assetIDs.insert(id); other.assetIDs.insert(id) }
   return (source, dest, other)
  }
  func req(_ id: String, _ source: String? = "source", _ action: GalleryDeleteAction = .moveToPhotos(destinationID: "dest", newName: nil)) -> GalleryDeleteRequest {
   .init(target: .photos(id, sourceAlbumID: source), action: action, sessionID: nil)
  }
  do {
   let (source, dest, other) = setup()
   let result = try await GalleryQueuedPhotoMove.execute(req("target"))
   check(result.destinationID == "dest" && source.assetIDs == ["unrelated"] && dest.assetIDs == ["target"] && other.assetIDs == ["target", "unrelated"], "move changed wrong memberships")
   check(Set(FakePhotoLibrary.assets.keys) == ["target", "unrelated"], "move deleted Photos assets")
  }
  do {
   let (source, dest, _) = setup(); source.assetIDs.remove("target")
   do { _ = try await GalleryQueuedPhotoMove.execute(req("target")); fatalError("stale source accepted") } catch {}
   check(source.assetIDs == ["unrelated"] && dest.assetIDs.isEmpty, "stale source caused mutation")
  }
  do {
   let (source, dest, _) = setup(); FakePhotoLibrary.mode = .failAfterBlock
   do { _ = try await GalleryQueuedPhotoMove.execute(req("target")); fatalError("failed Photos change accepted") } catch {}
   check(source.assetIDs == ["target", "unrelated"] && dest.assetIDs.isEmpty, "failed transaction changed memberships")
  }
  do {
   let (source, _, _) = setup()
   let result = try await GalleryQueuedPhotoMove.execute(req("target", "source", .moveToPhotos(destinationID: nil, newName: "New")))
   check(result.destinationID != nil && FakePhotoLibrary.collections[result.destinationID!]?.assetIDs == ["target"] && source.assetIDs == ["unrelated"], "create-and-move failed")
  }
  do {
   let (source, _, other) = setup()
   _ = try await GalleryQueuedPhotoMove.execute(req("target", "source", .removeFromAlbum))
   check(source.assetIDs == ["unrelated"] && other.assetIDs == ["target", "unrelated"] && FakePhotoLibrary.assets["target"] != nil, "remove from album touched other data")
  }
  do {
   let (source, _, other) = setup()
   let originalIDs = Set(FakePhotoLibrary.assets.keys)
   do {
    _ = try await GalleryQueuedPhotoMove.execute(req("target", "source", .moveToPhotos(destinationID: nil, newName: "Recycle Bin")))
    fatalError("reserved destination accepted")
   } catch {}
   check(source.assetIDs == ["target", "unrelated"] && other.assetIDs == ["target", "unrelated"], "reserved destination changed memberships")
   check(Set(FakePhotoLibrary.assets.keys) == originalIDs && FakePhotoLibrary.collections.count == 3, "reserved destination created a bin or changed IDs")
  }
  print("PASS exact move IDs, unrelated album, stale membership, transaction failure, create and remove (PhotoKit double)")
 }
}
