// Target audience: agents. Generated-data latency fixture for Simulator only.
import SwiftUI
import Combine
import Photos
import UIKit
import LocalAuthentication
import QuartzCore

@main struct SimpleVisionGalleryApp: App {
    init() {
        try? Data("core-contracts-generated-v1".utf8).write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("auto-build.txt"), options: .atomic)
        _ = DeleteFrameProbe.shared
        // Prime the Simulator's LocalAuthentication service before test-only biometric enrollment.
        try? Data("ready".utf8).write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("measurement-auth-ready.txt"))
    }
    var body: some Scene {
        WindowGroup { MeasurementPanel().frame(width: 780, height: 620).task { await NativeAutoTimings.shared.run() } }
        WindowGroup("Viewer", id: GalleryViewerWindows.sceneID, for: GalleryViewerWindowValue.self) { value in
            MeasurementViewer(value: value.wrappedValue)
        }
        WindowGroup("Paired Viewer", id: GalleryViewerWindows.pairSceneID, for: GalleryViewerWindowValue.self) { value in
            MeasurementViewer(value: value.wrappedValue)
        }
    }
}

@MainActor final class DeleteFrameProbe: NSObject, ObservableObject {
    static let shared = DeleteFrameProbe()
    @Published private(set) var result = "idle"
    private var armedLabel: String?
    private var started = 0.0
    private var lastFrame = 0.0
    private var firstFrame: Double?
    var proofFirstFrame: Double? { firstFrame }
    private var maximumGap = 0.0
    private var maximumPublish = 0.0
    private var maximumManagerPublish = 0.0
    private var maximumStorePublish = 0.0
    private var finishedAt: Double?
    private var link: CADisplayLink?

    override init() {
        super.init()
        let displayLink = CADisplayLink(target: self, selector: #selector(nextFrame(_:)))
        link = displayLink
        displayLink.add(to: .main, forMode: .common)
    }
    func arm(_ label: String) { armedLabel = label; result = "armed-" + label }
    func beginIfArmed() {
        guard armedLabel != nil else { return }
        started = CACurrentMediaTime()
        lastFrame = started
        firstFrame = nil
        maximumGap = 0
        maximumPublish = 0
        maximumManagerPublish = 0
        maximumStorePublish = 0
        finishedAt = nil
    }
    func finish() { finishedAt = CACurrentMediaTime() }
    func measureSynchronousPublish(_ work: () -> Void) {
        let started = CACurrentMediaTime()
        work()
        maximumPublish = max(maximumPublish, CACurrentMediaTime() - started)
    }
    func measureManagerPublish(_ work: () -> Void) {
        let started = CACurrentMediaTime()
        work()
        maximumManagerPublish = max(maximumManagerPublish, CACurrentMediaTime() - started)
    }
    func measureStorePublish(_ work: () -> Void) {
        let started = CACurrentMediaTime()
        work()
        maximumStorePublish = max(maximumStorePublish, CACurrentMediaTime() - started)
    }
    @objc private func nextFrame(_ displayLink: CADisplayLink) {
        guard armedLabel != nil, started > 0 else { return }
        let now = CACurrentMediaTime()
        let gap = now - lastFrame
        maximumGap = max(maximumGap, gap)
        lastFrame = now
        if firstFrame == nil { firstFrame = now }
        guard let finishedAt, now - finishedAt >= 0.5 else { return }
        let ms = Int(((firstFrame ?? now) - started) * 1000)
        let maxMs = Int(maximumGap * 1000)
        let label = armedLabel ?? "unknown"
        armedLabel = nil
        let publishMs = Int(maximumPublish * 1000)
        let managerMs = Int(maximumManagerPublish * 1000)
        let storeMs = Int(maximumStorePublish * 1000)
        result = "\(label)=\(ms)ms max=\(maxMs)ms publish=\(publishMs)ms manager=\(managerMs)ms store=\(storeMs)ms settle=500ms"
        started = 0
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("measurement-results.txt")
        let row = "\(label),\(ms),\(maxMs),\(publishMs),\(managerMs),\(storeMs)\n"
        if let bytes = row.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd(); try? handle.write(contentsOf: bytes); try? handle.close()
            } else { try? bytes.write(to: url, options: .atomic) }
        }
    }
}

@MainActor final class MeasurementState: ObservableObject {
    static let shared = MeasurementState()
    @Published var status = "Ready" { didSet { measurementStep(status) } }
    let manager = GalleryManager()
    let vault = GalleryVaultService.shared
    let storage = GalleryVaultStorage.shared
    let store = GalleryViewerStore.shared
    var photoSessionID: UUID?
    var photoCollectionID: String?
    var vaultSessionIDs: [UUID] = []

    var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func unlock() {
        status = "Unlocking"
        Task {
            do { try await vault.proofUnlockGeneratedRecords(); status = "Unlocked" }
            catch { status = "UnlockFailed" }
        }
    }

    func seedVault(_ count: Int, offset: Int = 0) {
        status = "SeedingVault-\(count)"
        Task {
            do {
                try storage.proofSeedRecords(count, offset: offset, previewData: GeneratedFixture.sampleJPEG)
                vault.proofPublishGeneratedRecords()
                await manager.loadAlbums()
                status = "VaultSeeded-\(storage.records.count)"
            } catch { status = "VaultSeedFailed" }
        }
    }

    func openVaultViewer(caseLabel: String, duplicate: Bool = false) {
        status = "OpeningVault-\(caseLabel)"
        Task {
            await manager.loadAlbums()
            guard let album = manager.albums.first(where: { $0.id == GeneratedFixture.albumID }) else {
                status = "VaultAlbumMissing"; return
            }
            await manager.openAlbum(album)
            guard let snapshot = manager.viewerSnapshot(), snapshot.count > 1,
                  let first = store.createSession(from: manager, at: snapshot.nativeCount) else {
                status = "VaultViewerMissing"; return
            }
            vaultSessionIDs = [first]
            if duplicate, let second = store.duplicateSession(first) { vaultSessionIDs.append(second) }
            DeleteFrameProbe.shared.arm(caseLabel)
            let value = GalleryViewerWindows.shared.makeWindow(sessionIDs: vaultSessionIDs)
            open(value)
            status = "ViewerOpen-\(caseLabel)"
        }
    }

    func seedPhotos(_ count: Int = 1000) {
        status = "PhotosAuth"
        Task {
            await manager.requestAuthorization()
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                status = "PhotosPermissionMissing"; return
            }
            do {
                if photoCollectionID == nil {
                    var albumID: String?
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                            withTitle: GeneratedFixture.photosTitle)
                        albumID = request.placeholderForCreatedAssetCollection.localIdentifier
                    }
                    photoCollectionID = albumID
                }
                guard let collectionID = photoCollectionID,
                      let collection = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [collectionID], options: nil).firstObject else {
                    status = "PhotosAlbumMissing"; return
                }
                let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).jpegData(withCompressionQuality: 0.8) { c in
                    UIColor.orange.setFill(); c.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
                }
                var placeholders: [PHObjectPlaceholder] = []
                status = "SeedingPhotos"
                try await PHPhotoLibrary.shared().performChanges {
                    for _ in 0..<count {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = "generated-measurement.jpg"
                        request.addResource(with: .photo, data: image, options: options)
                        if let placeholder = request.placeholderForCreatedAsset { placeholders.append(placeholder) }
                    }
                    PHAssetCollectionChangeRequest(for: collection)?.addAssets(placeholders as NSArray)
                }
                status = "PhotosSeeded-\(placeholders.count)"
            } catch { status = "PhotosSeedFailed" }
        }
    }

    func openPhotosViewer() {
        status = "OpeningPhotos"
        Task {
            await manager.loadAlbums()
            guard let album = manager.albums.first(where: { $0.title == GeneratedFixture.photosTitle }) else {
                status = "PhotosAlbumMissing"; return
            }
            await manager.openAlbum(album)
            guard let snapshot = manager.viewerSnapshot(), snapshot.count > 1,
                  let session = store.createSession(from: manager, at: 0) else {
                status = "PhotosViewerMissing"; return
            }
            photoSessionID = session
            DeleteFrameProbe.shared.arm("photos-1000")
            let value = GalleryViewerWindows.shared.makeWindow(sessionIDs: [session])
            open(value)
            status = "ViewerOpen-photos-1000"
        }
    }

    private func open(_ value: GalleryViewerWindowValue) {
        NotificationCenter.default.post(name: .measurementOpenViewer, object: value)
    }
}

private enum GeneratedFixture {
    static let albumID = "vault-album:generated-measurement"
    static let albumTitle = "Generated Measurement Vault"
    static let photosTitle = "Generated Auto Photos " + UUID().uuidString
    static let sampleJPEG = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).jpegData(withCompressionQuality: 0.8) { context in
        UIColor.orange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
    }
}

private extension Notification.Name { static let measurementOpenViewer = Notification.Name("measurement-open-viewer") }

struct MeasurementPanel: View {
    @StateObject private var state = MeasurementState.shared
    @ObservedObject private var probe = DeleteFrameProbe.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 12) {
            Text(state.status).accessibilityIdentifier("measurement-status")
            Text(probe.result).accessibilityIdentifier("measurement-result")
            Button("Unlock Generated Vault") { state.unlock() }.accessibilityIdentifier("measurement-unlock")
            Button("Seed 1,000 Vault Records") { state.seedVault(1000) }.accessibilityIdentifier("measurement-seed-1000")
            Button("Add 9,000 Vault Records") { state.seedVault(9000, offset: 1000) }.accessibilityIdentifier("measurement-add-9000")
            Button("Open 1,000 Vault Viewer") { state.openVaultViewer(caseLabel: "vault-1000") }.accessibilityIdentifier("measurement-open-vault-1000")
            Button("Open 10,000 Vault Viewer") { state.openVaultViewer(caseLabel: "vault-10000") }.accessibilityIdentifier("measurement-open-vault-10000")
            Button("Seed 1,000 Photos Items") { state.seedPhotos() }.accessibilityIdentifier("measurement-seed-photos")
            Button("Open Photos Viewer") { state.openPhotosViewer() }.accessibilityIdentifier("measurement-open-photos")
        }.padding()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("measurement-close-viewers"))) { _ in
            dismissWindow(id: GalleryViewerWindows.sceneID)
            dismissWindow(id: GalleryViewerWindows.pairSceneID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .measurementOpenViewer)) { note in
            guard let value = note.object as? GalleryViewerWindowValue else { return }
            openWindow(id: GalleryViewerWindows.sceneID(for: value), value: value)
        }
    }
}

struct MeasurementViewer: View {
    let value: GalleryViewerWindowValue?
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack {
            Button("Close generated viewer") { dismissWindow(id: GalleryViewerWindows.sceneID) }
                .accessibilityIdentifier("measurement-close-viewer")
            GalleryViewerWindowRoot(value: value)
        }
    }
}

nonisolated func measurementStep(_ step: String) {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("measurement-fixed-step.txt")
    try? Data(step.utf8).write(to: url, options: .atomic)
}
