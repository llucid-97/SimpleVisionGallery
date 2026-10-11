import SwiftUI

struct GalleryAboutView: View {
    @Environment(\.dismiss) private var dismiss
    private let repository = URL(string: "https://github.com/llucid-97/SimpleVisionGallery")!
    private let issues = URL(string: "https://github.com/llucid-97/SimpleVisionGallery/issues")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Simple Vision Gallery").font(.title2.weight(.semibold))
                    Text("Spatial photos, together.").foregroundStyle(.secondary)
                    Text(version).monospacedDigit().accessibilityIdentifier("gallery-about-version")
                }
                Section("Frequently Asked Questions") {
                    DisclosureGroup("How do spatial photos work?") {
                        Text("Open a photo and Gallery prepares a spatial scene on your device. Use the photo button below it to switch between spatial and 2D views. Some images cannot be converted and remain available in 2D.")
                    }
                    DisclosureGroup("Can I open more than one photo?") {
                        Text("Yes. Open more viewers or use Side by Side in a slideshow. Each viewer keeps the order it was opened with. Swipe left or right to browse.")
                    }
                    DisclosureGroup("What are Photos and Unfiled?") {
                        Text("Photos contains your photos and videos, except items in Recycle Bin. Unfiled contains media that is not in a regular Photos album. These are virtual views; Gallery does not create extra albums for them.")
                    }
                    DisclosureGroup("Does moving or removing an item delete it?") {
                        Text("Moving from an album adds the item to its destination and removes its old album membership. Remove from Album leaves the original in Photos. Moving from Photos files the item in the destination album.")
                    }
                    DisclosureGroup("How does Recycle Bin work?") {
                        Text("The bin button moves items into a Photos album named Recycle Bin. They stay in your Photos library until you permanently delete them from the bin. Apple Photos asks before permanent deletion; batches use one request.")
                    }
                    DisclosureGroup("Are spatial scenes saved permanently?") {
                        Text("No. Prepared scenes stay in a shared, limited memory cache. Gallery prepares nearby items while you browse. You can change how many it keeps ahead and behind in Settings.")
                    }
                }
                Section("Project and Known Issues") {
                    Link(destination: issues) { Label("Known Issues", systemImage: "ladybug") }
                        .accessibilityIdentifier("gallery-about-issues")
                    Link(destination: repository) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .accessibilityIdentifier("gallery-about-github")
                    Text("The GitHub repository is currently private. These links require an account with access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("Privacy Policy") { GalleryPrivacyView() }
                        .accessibilityIdentifier("gallery-about-privacy")
                    NavigationLink("Third-Party Licenses") { GalleryLicensesView() }
                        .accessibilityIdentifier("gallery-about-licenses")
                }
            }
            .navigationTitle("About")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 740)
        .accessibilityIdentifier("gallery-about")
    }
}

private struct GalleryPrivacyView: View {
    var body: some View {
        List {
            Section("Your Photos Library") {
                Text("Gallery uses Apple PhotoKit to show the photos, videos, and albums you allow it to access. Read and write access lets you create, rename, and organize albums and move items to Recycle Bin. You can change access in visionOS Settings.")
                Text("Spatial scenes are generated on your device and kept in a limited memory cache. Gallery does not save permanent converted copies to Photos.")
                Text("Recycle Bin is an ordinary Photos album. Permanent deletion is available inside the bin. Photos may keep deleted items in Recently Deleted. Album changes and deletions may sync through iCloud Photos if you use it.")
            }
            Section("Collection and Sharing") {
                Text("Gallery does not send your photos, videos, or preferences to the app developer. It has no accounts, advertising, analytics, tracking, or developer-run network service.")
                Text("Apple Photos may download originals from iCloud when Gallery opens them. Apple handles Photos and iCloud data under your settings and Apple's terms.")
            }
            Section("Local Settings") {
                Text("Gallery stores settings on your device, including accent color, album visibility and order, media filters, recent move destinations, thumbnail size, spatial prefetch, and video looping. Removing the app removes app-local settings. Changes made to your Photos library remain in Photos.")
            }
            Section("Before Public Release") {
                Text("A public policy URL and support mailbox will be added before the App Store release.")
            }
        }
        .navigationTitle("Privacy Policy")
    }
}

private struct GalleryLicensesView: View {
    var body: some View {
        List {
            Section("Software") {
                Text("This app does not bundle third-party software libraries. It uses Apple's system frameworks, including SwiftUI, PhotoKit, AVFoundation, RealityKit, and ImageIO, provided by visionOS.")
            }
            Section("Artwork") {
                Text("The app logo is original artwork. Interface symbols are Apple SF Symbols provided by the system. Your photos and videos remain yours.")
            }
        }
        .navigationTitle("Third-Party Licenses")
    }
}
