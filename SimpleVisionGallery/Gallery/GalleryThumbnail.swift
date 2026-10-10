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
