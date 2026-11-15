#if os(visionOS)
import AVFoundation
import RealityKit
import SwiftUI

/// One persistent RealityView owns both the playing surface and the fitted
/// lookahead surface. The next player is already attached behind the pane, so
/// promotion moves its existing entity instead of constructing a new renderer.
@MainActor
struct GallerySpatialVideoView: View {
    private struct SurfaceTaskIdentity: Hashable {
        let playerID: ObjectIdentifier?
        let componentPlayerID: ObjectIdentifier?
        let attachGeneration: UUID
    }

    let player: AVPlayer?
    let component: VideoPlayerComponent?
    let currentCovered: Bool
    let lookahead: GallerySpatialVideoLookahead?
    let isCurrentPlayer: (AVPlayer) -> Bool
    let onLookaheadDidAttach: (GallerySpatialVideoLookahead, Entity) -> Bool
    let onLookaheadDidFit: (GallerySpatialVideoLookahead, Entity) -> Bool
    let onLookaheadDidDetach: (GallerySpatialVideoLookahead, Entity) -> Void
    let onSurfaceAttached: (AVPlayer, UUID, Entity) -> Void
    let onSurfaceDetached: (AVPlayer, UUID) -> Void
    let onPlaybackRequest: (Bool, AVPlayer) -> Void
    var initialYawDegrees: Float = 0
    var initialPitchDegrees: Float = 0

    @State private var rootEntity = Entity()
    @State private var activeEntity: Entity?
    @State private var activePlayer: AVPlayer?
    @State private var activeSurfaceID: UUID?
    @State private var activeAttachDeadline: ContinuousClock.Instant?
    @State private var activeAttachGeneration = UUID()
    @State private var lookaheadEntity: Entity?
    @State private var lookaheadPlayer: AVPlayer?
    @State private var attachedLookahead: GallerySpatialVideoLookahead?
    @State private var fittedLookaheadID: UUID?
    @State private var fitRevision = 0
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    private var playerID: ObjectIdentifier? { player.map(ObjectIdentifier.init) }
    private var lookaheadID: UUID? { lookahead?.reservationID }
    private var surfaceTaskID: SurfaceTaskIdentity {
        SurfaceTaskIdentity(playerID: playerID,
            componentPlayerID: component?.avPlayer.map(ObjectIdentifier.init),
            attachGeneration: activeAttachGeneration)
    }

    var body: some View {
        VStack(spacing: 96) {
            GeometryReader3D { geometry in
                RealityView { content in
                    content.add(rootEntity)
                    synchronize(content: content, geometry: geometry)
                } update: { content in
                    _ = fitRevision
                    synchronize(content: content, geometry: geometry)
                }
                .onChange(of: initialYawDegrees) { _, _ in
                    applyOrientation(to: activeEntity)
                    applyOrientation(to: lookaheadEntity)
                }
                .onChange(of: initialPitchDegrees) { _, _ in
                    applyOrientation(to: activeEntity)
                    applyOrientation(to: lookaheadEntity)
                }
                .accessibilityLabel("Spatial video")
                .accessibilityIdentifier("gallery-spatial-video")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Height-only layout must not collapse the native video volume.
            .frame(depth: 540)

            if !currentCovered, let player, player === activePlayer {
                controls(for: player)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The native component reports its screen size asynchronously. Poll only
        // while a surface has not yet been fitted, then stop touching the scene.
        .task(id: lookaheadID) {
            guard let lookahead else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !Task.isCancelled, fittedLookaheadID != lookahead.reservationID,
                  ContinuousClock.now < deadline {
                fitRevision &+= 1
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
        .task(id: surfaceTaskID) {
            guard let player else {
                position = 0
                duration = 0
                isPlaying = false
                return
            }
            let deadline = activeAttachDeadline ?? ContinuousClock.now.advanced(by: .seconds(2))
            while !Task.isCancelled,
                  (activeSurfaceID == nil || component?.avPlayer !== player),
                  ContinuousClock.now < deadline {
                fitRevision &+= 1
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
            if !Task.isCancelled, activeSurfaceID == nil { fitRevision &+= 1 }
            while !Task.isCancelled {
                let nextDuration = player.currentItem?.duration.seconds ?? 0
                duration = nextDuration.isFinite && nextDuration > 0 ? nextDuration : 0
                if !isScrubbing {
                    let time = player.currentTime().seconds
                    position = time.isFinite ? min(max(time, 0), max(duration, 1)) : 0
                }
                isPlaying = player.timeControlStatus != .paused
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
        .onDisappear(perform: tearDown)
    }

    private func synchronize(content: RealityViewContent, geometry: GeometryProxy3D) {
        if let lookahead, lookahead.player !== player {
            if attachedLookahead?.matches(lookahead) != true {
                removeLookahead()
                let entity = Entity()
                entity.components.set(lookahead.component)
                entity.position = SIMD3<Float>(0, 0, -2)
                applyOrientation(to: entity)
                rootEntity.addChild(entity)
                lookaheadEntity = entity
                lookaheadPlayer = lookahead.player
                attachedLookahead = lookahead
                fittedLookaheadID = nil
                if !onLookaheadDidAttach(lookahead, entity) { removeLookahead() }
            }
        } else if lookaheadEntity != nil,
                  lookaheadPlayer !== player {
            removeLookahead()
        }

        if let player, let component, component.avPlayer === player {
            guard isCurrentPlayer(player) else {
                detachActive()
                if lookaheadPlayer === player { removeLookahead() }
                return
            }
            if lookaheadPlayer === player, let promoted = lookaheadEntity,
               promoted.parent === rootEntity,
               promoted.components[VideoPlayerComponent.self]?.avPlayer === player {
                detachActive()
                activeEntity = promoted
                activePlayer = player
                lookaheadEntity = nil
                lookaheadPlayer = nil
                attachedLookahead = nil
                fittedLookaheadID = nil
                var position = promoted.position
                position.z = 0
                promoted.position = position
            } else if activePlayer !== player {
                if lookaheadPlayer === player { removeLookahead() }
                detachActive()
                let entity = Entity()
                entity.components.set(component)
                applyOrientation(to: entity)
                rootEntity.addChild(entity)
                activeEntity = entity
                activePlayer = player
                activeAttachDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                activeAttachGeneration = UUID()
            }
        } else {
            detachActive()
        }

        if let entity = activeEntity {
            guard let player = activePlayer, isCurrentPlayer(player) else {
                detachActive()
                return
            }
            let fitted = fit(entity: entity, content: content, geometry: geometry,
                             depth: currentCovered ? -2 : 0)
            if fitted, activeSurfaceID == nil {
                let id = UUID()
                activeSurfaceID = id
                activeAttachDeadline = nil
                onSurfaceAttached(player, id, entity)
            } else if activeSurfaceID == nil,
                      let deadline = activeAttachDeadline, ContinuousClock.now >= deadline,
                      isCurrentPlayer(player) {
                // Do not strand playback if RealityKit never provides native sizing.
                let id = UUID()
                activeSurfaceID = id
                activeAttachDeadline = nil
                onSurfaceAttached(player, id, entity)
            }
        }

        if let entity = lookaheadEntity, let attachedLookahead {
            if fit(entity: entity, content: content, geometry: geometry, depth: -2,
                   requiresReadyRendering: true),
               fittedLookaheadID != attachedLookahead.reservationID {
                if onLookaheadDidFit(attachedLookahead, entity) {
                    fittedLookaheadID = attachedLookahead.reservationID
                } else {
                    removeLookahead()
                }
            }
        }
    }

    @discardableResult
    private func fit(entity: Entity, content: RealityViewContent,
                     geometry: GeometryProxy3D, depth: Float,
                     requiresReadyRendering: Bool = false) -> Bool {
        guard let component = entity.observable.components[VideoPlayerComponent.self],
              component.playerScreenSize.x.isFinite, component.playerScreenSize.y.isFinite,
              component.playerScreenSize.x > 0, component.playerScreenSize.y > 0 else { return false }
        let size = component.playerScreenSize
        if requiresReadyRendering, component.currentRenderingStatus != .ready { return false }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
        let scale = min(bounds.extents.x / size.x, bounds.extents.y / size.y)
        guard scale.isFinite, scale > 0 else { return false }
        entity.scale = SIMD3<Float>(repeating: scale)
        entity.position = SIMD3<Float>(bounds.center.x, bounds.center.y, depth)
        return true
    }

    private func removeLookahead() {
        if let entity = lookaheadEntity {
            if let attachedLookahead { onLookaheadDidDetach(attachedLookahead, entity) }
            entity.components.remove(VideoPlayerComponent.self)
            entity.removeFromParent()
        }
        lookaheadEntity = nil
        lookaheadPlayer = nil
        attachedLookahead = nil
        fittedLookaheadID = nil
    }

    private func detachActive() {
        if let activePlayer, let activeSurfaceID {
            onSurfaceDetached(activePlayer, activeSurfaceID)
        }
        activeSurfaceID = nil
        activeAttachDeadline = nil
        if let activeEntity {
            activeEntity.components.remove(VideoPlayerComponent.self)
            activeEntity.removeFromParent()
        }
        activeEntity = nil
        activePlayer = nil
    }

    private func tearDown() {
        detachActive()
        removeLookahead()
    }

    private func applyOrientation(to entity: Entity?) {
        entity?.components.remove(BillboardComponent.self)
        entity?.orientation = GalleryViewerPreferences.pairedOrientation(
            yawDegrees: initialYawDegrees, pitchDegrees: initialPitchDegrees)
    }

    @ViewBuilder
    private func controls(for player: AVPlayer) -> some View {
        HStack(spacing: 14) {
            Button { seek(to: position - 10, player: player) } label: {
                Image(systemName: "gobackward.10")
            }
            .accessibilityLabel("Skip back ten seconds")
            .accessibilityIdentifier("gallery-spatial-video-back")

            Button { togglePlayback(player) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(isPlaying ? "Pause video" : "Play video")
            .accessibilityIdentifier("gallery-spatial-video-play-pause")

            Button { seek(to: position + 10, player: player) } label: {
                Image(systemName: "goforward.10")
            }
            .accessibilityLabel("Skip ahead ten seconds")
            .accessibilityIdentifier("gallery-spatial-video-forward")

            Slider(value: $position, in: 0...max(duration, 1)) { editing in
                isScrubbing = editing
                if !editing { seek(to: position, player: player) }
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

    private func togglePlayback(_ player: AVPlayer) {
        let shouldPlay = player.timeControlStatus == .paused && player.rate == 0
        if shouldPlay, duration > 0, position >= duration - 0.1 { seek(to: 0, player: player) }
        onPlaybackRequest(shouldPlay, player)
        isPlaying = shouldPlay
    }

    private func seek(to seconds: Double, player: AVPlayer) {
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
