import Photos
import UIKit

@MainActor
final class GalleryShareExtensionViewController: UIViewController {
    private let status = UILabel()
    private let destination = UISegmentedControl(items: ["Photos", "Private Vault"])
    private let destinationDetail = UILabel()
    private var vaultPublicKey: Data?
    private var didSaveVault = false
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var staged: [StagedShare] = []
    private var stagingDirectory: URL?
    private var stagingLease: FileHandle?
    private var isSaving = false
    private var isDismissed = false
    private var saveTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.tintColor = UIColor(red: 1, green: 0.77, blue: 0.41, alpha: 1)
        preferredContentSize = CGSize(width: 520, height: 400)

        let title = UILabel()
        title.text = "Save to Gallery"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.accessibilityTraits.insert(.header)

        status.text = "Preparing shared items…"
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.numberOfLines = 0

        let destinationLabel = UILabel()
        destinationLabel.text = "Destination"
        destinationLabel.font = .preferredFont(forTextStyle: .headline)
        destinationLabel.adjustsFontForContentSizeCategory = true
        destinationLabel.accessibilityTraits.insert(.header)
        destination.selectedSegmentIndex = 0
        destination.accessibilityIdentifier = "gallery-share-destination"
        destination.addTarget(self, action: #selector(destinationChanged), for: .valueChanged)
        destination.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        destinationDetail.font = .preferredFont(forTextStyle: .subheadline)
        destinationDetail.adjustsFontForContentSizeCategory = true
        destinationDetail.textColor = .secondaryLabel
        destinationDetail.numberOfLines = 0
        destinationDetail.isHidden = true

        saveButton.configuration = .filled()
        saveButton.configuration?.baseBackgroundColor = view.tintColor
        saveButton.configuration?.baseForegroundColor = .black
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        saveButton.isEnabled = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, saveButton])
        buttons.axis = .horizontal
        buttons.spacing = 16
        buttons.distribution = .fillEqually
        saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        let stack = UIStackView(arrangedSubviews: [title, status, destinationLabel, destination, destinationDetail, buttons])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(28, after: status)
        stack.setCustomSpacing(8, after: destinationLabel)
        stack.setCustomSpacing(28, after: destinationDetail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -56)
        ])
        updateDestination()
        Task {
            vaultPublicKey = try? await Task.detached(priority: .utility) {
                try GalleryVaultInbox.availablePublicKey()
            }.value
            guard !isDismissed else { return }
            updateDestination()
        }

        prepareTask = Task { await prepareSharedItems() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isSaving {
            dismiss(cancelRequest: false)
        }
    }

    private func prepareSharedItems() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            fail("No photos or videos were shared.")
            return
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        do {
            let (directory, lease) = try await Task.detached(priority: .utility) {
                try GalleryShareInput.stagingDirectory()
            }.value
            stagingDirectory = directory
            stagingLease = lease
            var accepted: [StagedShare] = []
            for provider in providers {
                guard let type = GalleryShareInput.preferredType(for: provider) else {
                    throw NSError(domain: "GalleryShareExtension", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "One of the shared items is not a supported photo or video."])
                }
                let fallback = UUID().uuidString + "." + (type.preferredFilenameExtension ?? (type.conforms(to: .movie) ? "mov" : "jpg"))
                let result = try await GalleryShareInput.copyRepresentation(from: provider, type: type, to: directory, fallbackName: fallback)
                try Task.checkCancellation()
                accepted.append(result)
                status.text = "Prepared \(itemCount(accepted.count))…"
            }
            try Task.checkCancellation()
            guard !accepted.isEmpty else {
                fail("The shared items did not contain a supported photo or video.")
                return
            }
            staged = accepted
            status.text = "\(itemCount(accepted.count)) ready"
            updateDestination()
        } catch {
            cleanStaging()
            if Task.isCancelled {
                prepareTask = nil
                return
            }
            fail("Could not prepare the shared items: \(error.localizedDescription)")
        }
        prepareTask = nil
    }

    @objc private func destinationChanged() { updateDestination() }

    private func updateDestination() {
        let vault = destination.selectedSegmentIndex == 1
        saveButton.configuration?.title = vault ? "Save to Private Vault" : "Save to Photos"
        destinationDetail.isHidden = !vault
        destinationDetail.text = vaultPublicKey == nil
            ? "Open Gallery and unlock Private Vault once to enable sharing to it. Then share these items again."
            : "Encrypted on this device. Open Gallery and unlock Private Vault to finish importing."
        saveButton.isEnabled = !staged.isEmpty && !isSaving && saveTask == nil && (!vault || vaultPublicKey != nil) && !didSaveVault
    }

    @objc private func save() {
        guard !staged.isEmpty, !isSaving, saveTask == nil else { return }
        saveButton.isEnabled = false
        destination.isEnabled = false
        status.textColor = .secondaryLabel
        if destination.selectedSegmentIndex == 1 {
            guard vaultPublicKey != nil else { destination.isEnabled = true; updateDestination(); return }
            isSaving = true
            cancelButton.isEnabled = false
            status.text = "Encrypting \(itemCount(staged.count)) for Private Vault…"
            saveTask = Task { await saveToVault() }
        } else {
            status.text = "Requesting Photos permission…"
            saveTask = Task { await saveToPhotos() }
        }
    }

    private func saveToVault() async {
        let inputs = staged.map { GalleryVaultInbox.Input(url: $0.url, filename: $0.filename, typeIdentifier: $0.type.identifier) }
        do {
            let synced = try await Task.detached(priority: .userInitiated) { try await GalleryVaultInbox.save(items: inputs) }.value
            cleanStaging()
            saveTask = nil
            isSaving = false
            didSaveVault = true
            status.text = "Saved for Private Vault"
            destination.isEnabled = false
            destinationDetail.isHidden = false
            destinationDetail.text = synced
                ? "Open Gallery and unlock Private Vault to finish importing."
                : "The files were encrypted, but the final storage sync was not confirmed. Keep the originals until Gallery finishes importing."
            cancelButton.setTitle("Done", for: .normal)
            cancelButton.isEnabled = true
            saveButton.isHidden = true
        } catch {
            isSaving = false
            saveTask = nil
            destination.isEnabled = true
            cancelButton.isEnabled = true
            status.textColor = .systemRed
            status.text = "Could not save for Private Vault: \(error.localizedDescription)"
            updateDestination()
        }
    }

    private func saveToPhotos() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorization: PHAuthorizationStatus
        if current == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            authorization = current
        }
        guard !Task.isCancelled, !isDismissed else {
            saveTask = nil
            return
        }
        guard authorization == .authorized || authorization == .limited else {
            saveTask = nil
            cancelButton.isEnabled = true
            destination.isEnabled = true
            updateDestination()
            status.text = "Photos access was not granted. Allow adding photos in Settings, then try again."
            return
        }
        guard !staged.isEmpty else {
            saveTask = nil
            return
        }
        isSaving = true
        cancelButton.isEnabled = false
        status.text = "Saving \(itemCount(staged.count)) to Photos…"
        let itemsToSave = staged
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for item in itemsToSave {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = item.filename
                    let resourceType: PHAssetResourceType = item.type.conforms(to: .movie) ? .video : .photo
                    request.addResource(with: resourceType, fileURL: item.url, options: options)
                }
            }
            cleanStaging()
            saveTask = nil
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            isSaving = false
            saveTask = nil
            cancelButton.isEnabled = true
            destination.isEnabled = true
            updateDestination()
            status.text = "Could not save the items to Photos: \(error.localizedDescription)"
        }
    }

    @objc private func cancel() {
        guard !isSaving else { return }
        if didSaveVault {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        dismiss(cancelRequest: true)
    }

    private func dismiss(cancelRequest: Bool) {
        guard !isDismissed else { return }
        isDismissed = true
        prepareTask?.cancel()
        saveTask?.cancel()
        if cancelRequest {
            extensionContext?.cancelRequest(withError: NSError(domain: "GalleryShareExtension", code: NSUserCancelledError))
        }
        let pendingPreparation = prepareTask
        Task { [self] in
            await pendingPreparation?.value
            cleanStaging()
        }
    }

    private func itemCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "item" : "items")"
    }

    private func fail(_ message: String) {
        status.text = message
        saveButton.isEnabled = false
        cancelButton.isEnabled = true
    }

    private func cleanStaging() {
        staged.removeAll()
        if let stagingDirectory {
            do {
                try FileManager.default.removeItem(at: stagingDirectory)
                try? FileManager.default.removeItem(at: GalleryLeasedStaging.marker(for: stagingDirectory))
            } catch { } // Leave the marker so a later unlocked launch can retry cleanup.
        }
        stagingDirectory = nil
        try? stagingLease?.close()
        stagingLease = nil
    }

}
