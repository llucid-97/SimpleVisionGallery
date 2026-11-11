import Foundation
@main struct Test {
    static func main() {
        let photo = GalleryDeletionCandidate(localIdentifier: "generated-photo", mediaKind: .photo)
        let vaultID = UUID(), epoch = UUID()
        let vault = GalleryVaultDeletionCandidate(id: vaultID, mediaKind: .video)
        precondition(GalleryDeletionPlan(candidates: [], vaultCandidates: [vault]) == nil)
        precondition(GalleryDeletionPlan(candidates: [photo, photo]) == nil)
        precondition(GalleryDeletionPlan(candidates: [], vaultCandidates: [vault, vault], vaultEpoch: epoch) == nil)
        let plan = GalleryDeletionPlan(candidates: [photo], vaultCandidates: [vault], vaultEpoch: epoch,
                                       sourceAlbumID: "bin", photosBinID: "bin")!
        precondition(plan.totalCount == 2 && plan.photoCount == 1 && plan.videoCount == 1)
        precondition(plan.localIdentifiers == ["generated-photo"] && plan.vaultCandidates.map(\.id) == [vaultID])
        precondition(plan.matchesLiveCandidates([photo]))
        precondition(!plan.matchesLiveCandidates([]))
        var authority = GalleryDeletionReviewAuthority()
        authority.issue(plan)
        authority.invalidate()
        precondition(!authority.consume(plan))
        authority.issue(plan)
        precondition(authority.consume(plan))
        precondition(!authority.consume(plan))
        let vaultOnly = GalleryDeletionPlan(candidates: [], vaultCandidates: [vault], vaultEpoch: epoch)!
        precondition(vaultOnly.totalCount == 1 && vaultOnly.localIdentifiers.isEmpty)
        print("PASS: frozen IDs, store split, counts, cancellation, duplicate/replay and vault-only review")
    }
}
