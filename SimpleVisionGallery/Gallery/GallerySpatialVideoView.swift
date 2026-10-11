#if os(visionOS)
import AVFoundation
import RealityKit
import SwiftUI

/// AVKit's embedded player is monoscopic. A RealityKit portal keeps stereo playback
/// inside the gallery's fixed pane, including when two slideshows share a window.
struct GallerySpatialVideoView: View {
    let player: AVPlayer
    var initialYawDegrees: Float = 0
    @State private var videoEntity = Entity()
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var renderingID = UUID()

    var body: some View {
        VStack(spacing: 96) {
            video
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Spatial video")
                .accessibilityIdentifier("gallery-spatial-video")

            HStack(spacing: 14) {
                Button { seek(to: position - 10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("Skip back ten seconds")
                .accessibilityIdentifier("gallery-spatial-video-back")

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(isPlaying ? "Pause video" : "Play video")
                .accessibilityIdentifier("gallery-spatial-video-play-pause")

                Button { seek(to: position + 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("Skip ahead ten seconds")
                .accessibilityIdentifier("gallery-spatial-video-forward")

                Slider(value: $position, in: 0...max(duration, 1)) { editing in
                    isScrubbing = editing
                    if !editing { seek(to: position) }
                }
                .disabled(duration <= 0)
                .accessibilityLabel("Video position")
                .accessibilityValue("\(timeLabel(position)) of \(timeLabel(duration))")
                .accessibilityIdentifier("gallery-spatial-video-seek")

                Text("\(timeLabel(position)) / \(timeLabel(duration))")
                    .font(.caption.monospacedDigit())
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .task(id: ObjectIdentifier(player)) {
            let token = UUID()
            renderingID = token
            isScrubbing = false
            var component = VideoPlayerComponent(avPlayer: player)
            component.desiredViewingMode = .stereo
            component.desiredSpatialVideoMode = .spatial
            component.desiredImmersiveViewingMode = .portal
            component.isPassthroughTintingEnabled = false
            videoEntity.components.set(component)
            defer {
                if renderingID == token { videoEntity.components.remove(VideoPlayerComponent.self) }
            }
            // This view-owned task is cancelled automatically on item changes/close.
            while !Task.isCancelled {
                let nextDuration = player.currentItem?.duration.seconds ?? 0
                duration = nextDuration.isFinite && nextDuration > 0 ? nextDuration : 0
                if !isScrubbing {
                    let time = player.currentTime().seconds
                    position = time.isFinite ? min(max(time, 0), max(duration, 1)) : 0
                }
                isPlaying = player.timeControlStatus != .paused
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
            }
        }
    }

    @ViewBuilder
    private var video: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                // Match the initial inward angle of the paired window, then
                // keep it fixed so head movement reveals spatial parallax.
                videoEntity.components.remove(BillboardComponent.self)
                videoEntity.orientation = simd_quatf(angle: initialYawDegrees * .pi / 180, axis: [0, 1, 0])
                content.add(videoEntity)
                fit(content: content, geometry: geometry)
            } update: { content in
                fit(content: content, geometry: geometry)
            }
        }
        // Height-only layout must not collapse the native video volume.
        .frame(depth: 540)
    }

    private func fit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard let size = videoEntity.observable.components[VideoPlayerComponent.self]?.playerScreenSize,
              size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
        let scale = min(bounds.extents.x / size.x, bounds.extents.y / size.y)
        guard scale.isFinite, scale > 0 else { return }
        videoEntity.scale = SIMD3<Float>(repeating: scale)
        // Keep the RealityView's forward depth; scene Z=0 puts the native
        // media surface behind the window backing. Center in content space.
        videoEntity.position = SIMD3<Float>(bounds.center.x, bounds.center.y, 0)
    }

    private func togglePlayback() {
        if player.timeControlStatus != .paused {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && position >= duration - 0.1 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        guard duration > 0 else { return }
        position = min(max(seconds, 0), duration)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

#endif
