import SwiftUI
@preconcurrency import Photos

/// Capture the selected items before showing the confirmation.
struct GalleryVaultTransferRequest: Identifiable {
    let id = UUID()
    let title: String
    let destinationTitle: String?
    let transfer: @MainActor () async throws -> GalleryVaultTransferOutcome
    var enqueueOnConfirmation: (@MainActor () -> Void)? = nil

    static func items(_ assets: [PHAsset], destination: GalleryVaultAlbum? = nil, sourceAlbumID: String? = nil) -> Self {
        Self(title: "\(assets.count) item\(assets.count == 1 ? "" : "s")", destinationTitle: destination?.title) {
            try await GalleryVaultService.shared.moveToVault(assets: assets, destination: destination, sourceAlbumID: sourceAlbumID)
        }
    }

    static func queuedItem(_ asset: PHAsset, destination: GalleryVaultAlbum, sourceAlbumID: String?, sessionID: UUID) -> Self {
        let epoch = GalleryVaultService.shared.authEpoch
        var request = Self.items([asset], destination: destination, sourceAlbumID: sourceAlbumID)
        request.enqueueOnConfirmation = {
            guard GalleryVaultService.shared.isUnlocked, GalleryVaultService.shared.authEpoch == epoch else { return }
            GalleryDeleteQueue.shared.enqueueMove(item: .photos(asset), sourceAlbumID: sourceAlbumID, sessionID: sessionID,
                action: .moveToVault(id: destination.id, epoch: epoch, sourceAlbumID: sourceAlbumID), vaultDestination: destination)
        }
        return request
    }

    static func album(_ title: String, fetch: PHFetchResult<PHAsset>, id: String) -> Self {
        Self(title: "Album \(title)", destinationTitle: nil) {
            try await GalleryVaultService.shared.moveToVault(fetch: fetch, sourceAlbumID: id)
        }
    }
}

struct GalleryVaultConfirmation: ViewModifier {
    @Binding var request: GalleryVaultTransferRequest?
    @Binding var showingVault: Bool
    @Binding var resultMessage: String?
    func body(content: Content) -> some View {
        content.alert(
            "Move \(request?.title ?? "items") to \(request?.destinationTitle.map { "Private Vault album “" + $0 + "”" } ?? "Private Vault")?",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { target in
            Button("Move to Private Vault", role: .destructive) {
                if let enqueue = target.enqueueOnConfirmation { enqueue(); request = nil; return }
                showingVault = true
                resultMessage = nil
                Task { @MainActor in
                    var wasUnlocked = false
                    do {
                        if !GalleryVaultService.shared.isUnlocked {
                            try await GalleryVaultService.shared.unlock()
                        }
                        wasUnlocked = true
                        let outcome = try await target.transfer()
                        if GalleryVaultService.shared.isUnlocked {
                            resultMessage = GalleryVaultView.message(for: outcome)
                        }
                    } catch {
                        if !wasUnlocked || GalleryVaultService.shared.isUnlocked {
                            resultMessage = error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The vault is encrypted and stored on this device. Deleting the app, losing the device, or removing its passcode may make these items unrecoverable. After the copies are saved, Photos will ask to delete the originals from your library, all their Photos albums, and iCloud devices. Recently Deleted can continue using storage. This vault is separate from Apple's Hidden album.")
        }
    }
}

enum GalleryVaultNoticePreferences {
    static let hideDeviceWarningKey = "gallery.vault.hideDeviceWarning.v1"
}

struct GalleryVaultView: View {
    @ObservedObject private var vault = GalleryVaultService.shared
    @Binding var resultMessage: String?
    @Binding var albumRetryIDs: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var unlockError: String?
    @AppStorage(GalleryVaultNoticePreferences.hideDeviceWarningKey) private var hideDeviceWarning = false
    @State private var albumDeletion: GalleryAlbumDeletionPlan?
    @State private var pendingCopies: [GalleryVaultRecord] = []
    @State private var pendingVisibleCount = 50
    @State private var discardIDs: [UUID] = []
    @State private var confirmDiscard = false
    @State private var confirmAlbumRetry = false
    @State private var confirmDiscardAlbumDeletion = false
    @State private var confirmFinishAlbumDeletion = false

    private var restorableRecords: [GalleryVaultRecord] {
        vault.records.filter { $0.state == .privateItem && !GalleryVaultRecycleBin.contains($0) }
    }

    private var interruptedRestores: [GalleryVaultRecord] {
        vault.records.filter { $0.state == .restoring && !GalleryVaultRecycleBin.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Private Vault", systemImage: vault.isUnlocked ? "lock.open" : "lock")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(LensLabSecondaryButtonStyle())
            }
            Group {
                if vault.isUnlocked {
                    ScrollView { vaultContents }
                } else {
                    ViewThatFits(in: .vertical) {
                        vaultContents
                        ScrollView { vaultContents }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 580, minHeight: 360)
        .galleryLightBackdrop(cornerRadius: 24)
        .accessibilityIdentifier("gallery-vault-sheet")
        .onReceive(vault.$records) { records in
            pendingCopies = records.filter { $0.state == .copiedAwaitingDeletion }
            pendingVisibleCount = min(max(50, pendingVisibleCount), max(50, pendingCopies.count))
        }
        .onChange(of: vault.isUnlocked) { _, unlocked in
            if !unlocked {
                resultMessage = nil
                albumDeletion = nil
                confirmDiscardAlbumDeletion = false
                confirmFinishAlbumDeletion = false
                unlockError = nil
                pendingCopies = []
                discardIDs = []
                albumRetryIDs = []
                confirmDiscard = false
                confirmAlbumRetry = false
            }
        }
        .alert("Discard saved copies?", isPresented: $confirmDiscard) {
            Button("Discard Copies", role: .destructive) {
                let ids = discardIDs
                discardIDs = []
                resultMessage = nil
                Task { @MainActor in
                    do {
                        try await vault.discardPendingCopies(recordIDs: ids)
                        if vault.isUnlocked { resultMessage = "Saved copies discarded; originals remain in Photos." }
                    } catch {
                        if vault.isUnlocked { resultMessage = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { discardIDs = [] }
        } message: {
            Text("Only saved vault copies whose originals are still in Photos can be discarded. The originals stay in Photos. To move them into the vault later, start the move again.")
        }
        .alert("Restore without unavailable albums?", isPresented: $confirmAlbumRetry) {
            Button("Restore Without Those Albums") {
                let ids = albumRetryIDs
                albumRetryIDs = []
                restore(ids, omittingUnavailableAlbums: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos cannot restore some original albums because they are missing or cannot be edited. Restored items will be added to available albums, but not to those unavailable albums.")
        }
        .confirmationDialog("Finish Without Remaining Items?", isPresented: $confirmFinishAlbumDeletion, titleVisibility: .visible) {
            Button("Finish Without Remaining Items") {
                do { try vault.finishAlbumDeletionWithoutRemainingItems() }
                catch { unlockError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(vault.albumDeletionRemainingCount) item\(vault.albumDeletionRemainingCount == 1 ? "" : "s") will keep “\(vault.pendingAlbumDeletion?.plan.title ?? "this album")” in their vault memberships. This clears the cleanup note only. No photos or vault items will be changed or deleted.")
        }
        .confirmationDialog("Discard unreadable recovery note?", isPresented: $confirmDiscardAlbumDeletion, titleVisibility: .visible) {
            Button("Discard Recovery Note") {
                do { try vault.discardUnreadableAlbumDeletion() }
                catch { unlockError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Discarding this note changes no photos, vault files or vault album memberships. Your vault memberships stay as they are now. Any Photos album change already made is not undone.")
        }
        .sheet(item: $albumDeletion, onDismiss: { vault.isReviewingAlbumDeletion = false }) { plan in GalleryAlbumDeletionSheet(plan: plan, isRecoveryReview: true) }

    }

    private var vaultContents: some View {
        VStack(alignment: .leading, spacing: 18) {
            if vault.isUnlocked {
                if vault.needsAlbumDeletionReview {
                    Text("Album cleanup needs review. Your readable private items remain available. Moving and restoring are paused until this is resolved.")
                    if let error = vault.albumDeletionRecoveryError {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("gallery-album-recovery-error")
                        Button("Retry Album Cleanup") { vault.retryAlbumDeletionRecovery() }
                            .disabled(vault.isBusy)
                        if vault.pendingAlbumDeletion?.photosCommitted == true {
                            Button("Finish Without Remaining Items") { confirmFinishAlbumDeletion = true }
                                .disabled(vault.isBusy)
                                .accessibilityIdentifier("gallery-album-cleanup-finish")
                        }
                    }
                    if vault.pendingAlbumDeletion == nil {
                        Button("Discard Unreadable Recovery Note…") { confirmDiscardAlbumDeletion = true }
                            .disabled(vault.isBusy)
                    } else if vault.pendingAlbumDeletion?.photosCommitted == false {
                        Button("Review Interrupted Album Deletion") {
                            Task { @MainActor in
                                do {
                                    let plan = try await vault.reviewInterruptedAlbumDeletion()
                                    vault.isReviewingAlbumDeletion = true
                                    albumDeletion = plan
                                }
                                catch { unlockError = error.localizedDescription }
                            }
                        }.disabled(vault.isBusy)
                    }
                }
                Button("Lock Vault", systemImage: "lock") { vault.lock() }
                    .buttonStyle(LensLabSecondaryButtonStyle())
                    .accessibilityIdentifier("gallery-vault-lock")
                if vault.unreadableRecordCount > 0 {
                    Text("\(vault.unreadableRecordCount) saved item\(vault.unreadableRecordCount == 1 ? "" : "s") could not be read. Their files have been kept; any readable private items remain available.")
                        .font(.callout)
                        .foregroundStyle(LensLabTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("gallery-vault-unreadable-warning")
                }
            } else {
                Button("Unlock Vault", systemImage: "lock.open") {
                    unlockError = nil
                    Task { @MainActor in
                        do { try await vault.unlock() }
                        catch { unlockError = error.localizedDescription }
                    }
                }
                .buttonStyle(LensLabPrimaryButtonStyle())
                .disabled(vault.isBusy)
                .accessibilityIdentifier("gallery-vault-unlock")
            }

            if let progress = vault.progress, vault.isBusy || progress.phase == "Restoring" {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress.phase).font(.headline)
                    ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                    Text("\(progress.processed) of \(progress.total)")
                        .font(.callout.monospacedDigit())
                    if let detail = progress.detail {
                        Text(detail).font(.callout).foregroundStyle(LensLabTheme.mutedInk)
                    }
                    if vault.isBusy {
                        Button("Stop") { vault.cancel() }
                            .buttonStyle(LensLabSecondaryButtonStyle())
                        Text(progress.phase == "Restoring"
                             ? "Completed items stay restored. Any remaining items stay in the vault."
                             : "The current copy may stop. Already saved items can still be removed from Photos as one batch.")
                            .font(.caption)
                            .foregroundStyle(LensLabTheme.mutedInk)
                    }
                }
                .accessibilityIdentifier("gallery-vault-progress")
            }

            if vault.isUnlocked && !vault.isBusy {
                if !interruptedRestores.isEmpty {
                    Button("Resume Interrupted Restores", systemImage: "arrow.clockwise") {
                        let ids = interruptedRestores.map(\.id)
                        restore(ids)
                    }
                    .buttonStyle(LensLabSecondaryButtonStyle())
                }
                Button("Restore All Private Items", systemImage: "lock.open") {
                    restore(restorableRecords.map(\.id))
                }
                .buttonStyle(LensLabSecondaryButtonStyle())
                .disabled(restorableRecords.isEmpty)

                Button("Retry Removing Saved Originals", systemImage: "arrow.clockwise") {
                    resultMessage = nil
                    Task { @MainActor in
                        do {
                            let outcome = try await vault.retryPendingDeletion()
                            resultMessage = Self.message(for: outcome)
                        } catch {
                            if vault.isUnlocked { resultMessage = error.localizedDescription }
                        }
                    }
                }
                .buttonStyle(LensLabSecondaryButtonStyle())
                Text("Use this if copies were saved but Photos did not remove the originals.")
                    .font(.caption)
                    .foregroundStyle(LensLabTheme.mutedInk)

                if !albumRetryIDs.isEmpty {
                    Button("Restore Without Unavailable Albums", systemImage: "exclamationmark.triangle") {
                        confirmAlbumRetry = true
                    }
                    .buttonStyle(LensLabSecondaryButtonStyle())
                    .accessibilityIdentifier("gallery-vault-retry-missing-albums")
                }

                if !pendingCopies.isEmpty {
                    Text("Saved copies awaiting removal from Photos")
                        .font(.headline)
                    Text("Removal from Photos has not been confirmed. Retry removal, or discard a saved copy if its original is still in Photos.")
                        .font(.callout)
                        .foregroundStyle(LensLabTheme.mutedInk)
                    Button("Discard All Saved Copies", systemImage: "trash") {
                        discardIDs = pendingCopies.map(\.id)
                        confirmDiscard = true
                    }
                    .buttonStyle(LensLabSecondaryButtonStyle())
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pendingCopies.prefix(pendingVisibleCount)) { record in
                            HStack {
                                Text(record.filename)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Discard Copy", systemImage: "trash") {
                                    discardIDs = [record.id]
                                    confirmDiscard = true
                                }
                                .labelStyle(.iconOnly)
                                .help("Discard saved copy")
                            }
                        }
                    }
                    if pendingVisibleCount < pendingCopies.count {
                        Button("Show More Saved Copies") {
                            pendingVisibleCount = min(pendingCopies.count, pendingVisibleCount + 50)
                        }
                        .buttonStyle(LensLabSecondaryButtonStyle())
                    }
                }
            }

            if let message = unlockError ?? resultMessage ?? vault.error {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gallery-vault-message")
            }

            if !hideDeviceWarning && !vault.isBusy {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Stored only on this device", systemImage: "exclamationmark.shield")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.red)
                    Text("Deleting the app or losing this device can remove the only copies. Removing your device passcode may make saved items impossible to open.")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Don't show again") { hideDeviceWarning = true }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("gallery-vault-hide-device-warning")
                }
                .padding(16)
                .galleryLightSurface(role: .raised, cornerRadius: 16)
                .accessibilityIdentifier("gallery-vault-device-warning")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restore(_ ids: [UUID], omittingUnavailableAlbums: Bool = false) {
        guard !ids.isEmpty, !vault.isBusy else { return }
        albumRetryIDs = []
        resultMessage = nil
        Task { @MainActor in
            do {
                try await vault.restore(recordIDs: ids, omittingUnavailableAlbums: omittingUnavailableAlbums)
                if vault.isUnlocked { resultMessage = "Restore completed." }
            } catch {
                if vault.isUnlocked {
                    resultMessage = error.localizedDescription
                    if let failure = error as? GalleryVaultTransferError,
                       case .albumUnavailable = failure { albumRetryIDs = ids }
                }
            }
        }
    }

    static func message(for outcome: GalleryVaultTransferOutcome) -> String {
        var summary = "Saved this time: \(outcome.copied). Already saved and verified: \(outcome.reused). Removed from Photos: \(outcome.deleted). Left in Photos: \(outcome.notMoved)."
        if outcome.editsDiscarded > 0 { summary += " Edits discarded: \(outcome.editsDiscarded). Originals saved." }
        let skipped = GalleryVaultSkipReason.allCases.compactMap { reason -> String? in
            guard let count = outcome.skipped[reason], count > 0 else { return nil }
            return "\(reason.rawValue): \(count)"
        }
        if !skipped.isEmpty { summary += " Skipped: " + skipped.joined(separator: "; ") + "." }
        return outcome.message.map { summary + " " + $0 } ?? summary
    }
}

/// One shared session indicator for gallery and viewer toolbars.
struct GalleryVaultSessionButton: View {
    @ObservedObject private var vault = GalleryVaultService.shared

    var body: some View {
        if vault.isUnlocked {
            Button { vault.lock() } label: {
                Label("Lock Private Vault", systemImage: "lock.open")
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .buttonStyle(.borderless)
            .help("Private Vault is open. Private items are included in albums and slideshows. Select to lock.")
            .accessibilityLabel("Private Vault open. Lock Private Vault")
            .accessibilityIdentifier("gallery-vault-session-lock")
        }
    }
}

/// Authenticate before exposing encrypted destination titles.
struct GalleryVaultAlbumsToggle: View {
    @Binding var isOn: Bool
    @ObservedObject private var vault = GalleryVaultService.shared
    @State private var error: String?

    var body: some View {
        Toggle("Vault Albums", isOn: Binding(get: { isOn && vault.isUnlocked }, set: { enabled in
            error = nil
            if !enabled { isOn = false; return }
            Task { @MainActor in
                do {
                    try await vault.unlock()
                    isOn = vault.isUnlocked
                } catch { self.error = error.localizedDescription }
            }
        }))
        .disabled(vault.isBusy)
        .accessibilityIdentifier("gallery-move-vault-albums")
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}
