#if os(visionOS)
import AVFoundation
import ImageIO
@preconcurrency import Photos
import SwiftUI
import UIKit

struct GalleryThumbnail: View {
    let item: GalleryMediaItem
    let manager: GalleryManager

    init(asset: PHAsset, manager: GalleryManager) { self.item = .photos(asset); self.manager = manager }
    init(item: GalleryMediaItem, manager: GalleryManager) { self.item = item; self.manager = manager }

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var requestGeneration = 0
    @State private var vaultTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LensLabTheme.previewSurface.opacity(0.10))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.mediaType == .video ? "video" : "photo")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(LensLabTheme.mutedInk.opacity(0.68))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear(perform: loadThumbnail)
        .onDisappear {
            cancelRequest()
            if item.vaultRecord != nil { image = nil }
        }
        .onChange(of: item.localIdentifier) {
            image = nil
            cancelRequest()
            loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .galleryPhotosAccessDidRevoke)) { _ in
            if item.photosAsset != nil {
                cancelRequest()
                image = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .galleryVaultWillLock)) { _ in
            if item.vaultRecord != nil {
                cancelRequest()
                image = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .galleryVaultDidHideItems)) { note in
            let ids = note.userInfo?["sourceIdentifierSet"] as? Set<String>
                ?? Set(note.userInfo?["sourceIdentifiers"] as? [String] ?? [])
            if ids.contains(item.localIdentifier) {
                cancelRequest()
                image = nil
            }
        }
    }

    private func loadThumbnail() {
        guard requestID == nil, vaultTask == nil, image == nil else { return }
        requestGeneration += 1
        let generation = requestGeneration
        if let asset = item.photosAsset {
            requestID = manager.requestThumbnail(for: asset) { nextImage, isFinal in
                guard requestGeneration == generation else { return }
                if let nextImage { image = nextImage }
                if isFinal { requestID = nil }
            }
            return
        }
        guard let record = item.vaultRecord, record.mediaType == PHAssetMediaType.image.rawValue,
              let resource = GalleryVaultResourceSelection.displayResource(for: record) else { return }
        vaultTask = Task { @MainActor in
            defer { if requestGeneration == generation { vaultTask = nil } }
            do {
                try await GalleryVaultThumbnailGate.shared.acquire()
                defer { GalleryVaultThumbnailGate.shared.release() }
                let url = try await GalleryVaultStorage.shared.decryptResource(recordID: record.id, resourceID: resource.id)
                defer { GalleryVaultStorage.shared.releasePlaintext(url) }
                try Task.checkCancellation()
                let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
                    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
                    let options = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(UIImage.init(cgImage:))
                }.value
                try Task.checkCancellation()
                guard requestGeneration == generation, GalleryVaultStorage.shared.isUnlocked else { return }
                image = thumbnail
            } catch {
                // An unavailable or locked item keeps its neutral placeholder.
            }
        }
    }

    private func cancelRequest() {
        requestGeneration += 1
        if let requestID { manager.cancelImageRequest(requestID) }
        requestID = nil
        vaultTask?.cancel()
        vaultTask = nil
    }
}

/// Avoid decrypting dozens of visible thumbnails at once on large albums.
@MainActor
private final class GalleryVaultThumbnailGate {
    static let shared = GalleryVaultThumbnailGate()
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiters.firstIndex(where: { $0.0 == id }) {
                    self.waiters.remove(at: index).1.resume(throwing: CancellationError())
                }
            }
        }
    }

    func release() {
        if waiters.isEmpty { active = max(0, active - 1) }
        else { waiters.removeFirst().1.resume() }
    }
}
#else
//
//  GalleryThumbnail.swift
//  simple_vision_tools
//

#if canImport(UIKit) || canImport(AppKit)
    @preconcurrency import Photos
    import SwiftUI
    #if canImport(UIKit)
        import UIKit
    #else
        import AppKit
    #endif

    struct GalleryThumbnail: View {
        let asset: PHAsset
        let manager: GalleryManager

        @State private var image: GalleryPlatformImage?
        @State private var requestID: PHImageRequestID?
        @State private var requestGeneration = 0

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LensLabTheme.previewSurface.opacity(0.10))

                if let image {
                    platformImage(image)
                } else {
                    Image(systemName: asset.mediaType == .video ? "video" : "photo")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(LensLabTheme.mutedInk.opacity(0.68))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear(perform: loadThumbnail)
            .onDisappear(perform: cancelRequest)
            .onChange(of: asset.localIdentifier) {
                image = nil
                cancelRequest()
                loadThumbnail()
            }
        }

        @ViewBuilder
        private func platformImage(_ image: GalleryPlatformImage) -> some View {
            #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            #else
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            #endif
        }

        private func loadThumbnail() {
            guard requestID == nil, image == nil else {
                return
            }

            requestGeneration += 1
            let generation = requestGeneration
            requestID = manager.requestThumbnail(for: asset) { nextImage, isFinal in
                guard requestGeneration == generation else {
                    return
                }

                if let nextImage {
                    image = nextImage
                }
                if isFinal {
                    requestID = nil
                }
            }
        }

        private func cancelRequest() {
            requestGeneration += 1
            if let requestID {
                manager.cancelImageRequest(requestID)
            }
            requestID = nil
        }
    }
#endif

#endif
