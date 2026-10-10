#if os(visionOS)
import Combine
import Foundation
import UIKit

struct GalleryViewerWindowValue: Codable, Hashable, Identifiable {
    let id: UUID
    let sessionIDs: [UUID]
}

/// Window values hold playlist leases so arranging never loses either cursor.
@MainActor
final class GalleryViewerWindows: ObservableObject {
    static let shared = GalleryViewerWindows()
    static let sceneID = "gallery-viewer"
    static let pairSceneID = "gallery-viewer-pair"

    static func sceneID(for value: GalleryViewerWindowValue) -> String {
        value.sessionIDs.count == 2 ? pairSceneID : sceneID
    }

    @Published private(set) var windows: [GalleryViewerWindowValue] = []
    private var replacements: [UUID: [GalleryViewerWindowValue]] = [:]
    private var sceneWindows: [String: GalleryViewerWindowValue] = [:]
    private var disconnectObserver: NSObjectProtocol?

    private init() {
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIScene else { return }
            let sceneID = scene.session.persistentIdentifier
            Task { @MainActor [weak self] in
                guard let self, let value = self.sceneWindows.removeValue(forKey: sceneID) else { return }
                self.closed(value)
            }
        }
    }

    func attach(_ value: GalleryViewerWindowValue, to scene: UIWindowScene) {
        sceneWindows[scene.session.persistentIdentifier] = value
    }

    func makeWindow(sessionIDs: [UUID]) -> GalleryViewerWindowValue {
        let value = GalleryViewerWindowValue(id: UUID(), sessionIDs: sessionIDs)
        register(value)
        return value
    }

    func register(_ value: GalleryViewerWindowValue) {
        if !windows.contains(where: { $0.id == value.id }) { windows.append(value) }
    }

    func canArrange(_ value: GalleryViewerWindowValue) -> Bool {
        value.sessionIDs.count == 1 && windows.contains(where: { $0.id == value.id })
            && !isBeingReplaced(value) && windows.contains {
            $0.id != value.id && $0.sessionIDs.count == 1 && $0.sessionIDs != value.sessionIDs
                && !isBeingReplaced($0)
        }
    }

    private func isBeingReplaced(_ value: GalleryViewerWindowValue) -> Bool {
        replacements.values.contains { $0.contains(where: { $0.id == value.id }) }
    }

    func arrange(_ value: GalleryViewerWindowValue) -> GalleryViewerWindowValue? {
        guard canArrange(value), let other = windows.last(where: {
            $0.id != value.id && $0.sessionIDs.count == 1 && $0.sessionIDs != value.sessionIDs
                && !isBeingReplaced($0)
        }) else { return nil }
        let pair = makeWindow(sessionIDs: value.sessionIDs + other.sessionIDs)
        replacements[pair.id] = [value, other]
        return pair
    }

    func takeReplacements(for value: GalleryViewerWindowValue) -> [GalleryViewerWindowValue] {
        replacements.removeValue(forKey: value.id) ?? []
    }

    func closed(_ value: GalleryViewerWindowValue) {
        windows.removeAll { $0.id == value.id }
        replacements.removeValue(forKey: value.id)
        for sessionID in value.sessionIDs where !windows.contains(where: { $0.sessionIDs.contains(sessionID) }) {
            GalleryViewerStore.shared.disposeSession(sessionID)
        }
    }
}
#endif
