import Photos
import UIKit

@MainActor
final class GalleryShareExtensionViewController: UIViewController {
    private let status = UILabel()
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var staged: [StagedShare] = []
    private var stagingDirectory: URL?
    private var isSaving = false
    private var saveTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)

        let title = UILabel()
        title.text = "Save to Simple Vision Gallery"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        status.text = "Preparing shared items…"
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0

        saveButton.setTitle("Save to Photos", for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        saveButton.isEnabled = false

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [saveButton, cancelButton])
        buttons.axis = .horizontal
        buttons.spacing = 16
        buttons.distribution = .fillEqually
        saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [title, status, buttons])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])

        prepareTask = Task { await prepareSharedItems() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isSaving {
            prepareTask?.cancel()
            Task { [weak self] in
                await self?.prepareTask?.value
                self?.cleanStaging()
            }
        }
    }

    private func prepareSharedItems() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            fail("No photos or videos were shared.")
            return
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryIncoming-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stagingDirectory = directory
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
                status.text = "Prepared \(accepted.count) item(s)…"
            }
            try Task.checkCancellation()
            guard !accepted.isEmpty else {
                fail("The shared items did not contain a supported photo or video.")
                return
            }
            staged = accepted
            status.text = "\(accepted.count) item(s) ready. Choose Save to add copies to Photos."
            saveButton.isEnabled = true
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

    @objc private func save() {
        guard !staged.isEmpty, !isSaving, saveTask == nil else { return }
        saveButton.isEnabled = false
        status.text = "Requesting Photos permission…"
        saveTask = Task { await saveToPhotos() }
    }

    private func saveToPhotos() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorization: PHAuthorizationStatus
        if current == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            authorization = current
        }
        guard authorization == .authorized || authorization == .limited else {
            saveTask = nil
            cancelButton.isEnabled = true
            saveButton.isEnabled = true
            status.text = "Photos access was not granted. Allow adding photos in Settings, then try again."
            return
        }
        guard !Task.isCancelled else { return }
        isSaving = true
        cancelButton.isEnabled = false
        status.text = "Saving \(staged.count) item(s) to Photos…"
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
            saveButton.isEnabled = true
            status.text = "Could not save the items to Photos: \(error.localizedDescription)"
        }
    }

    @objc private func cancel() {
        guard !isSaving else { return }
        if let prepareTask {
            cancelButton.isEnabled = false
            saveButton.isEnabled = false
            status.text = "Cancelling…"
            prepareTask.cancel()
            Task { [weak self] in
                await prepareTask.value
                guard let self else { return }
                self.cleanStaging()
                self.extensionContext?.cancelRequest(withError: NSError(domain: "GalleryShareExtension", code: NSUserCancelledError))
            }
            return
        }
        saveTask?.cancel()
        cleanStaging()
        extensionContext?.cancelRequest(withError: NSError(domain: "GalleryShareExtension", code: NSUserCancelledError))
    }

    private func fail(_ message: String) {
        status.text = message
        saveButton.isEnabled = false
        cancelButton.isEnabled = true
    }

    private func cleanStaging() {
        staged.removeAll()
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
    }

}
