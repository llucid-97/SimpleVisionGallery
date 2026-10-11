import SwiftUI

struct GallerySettingsView: View {
    @ObservedObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingAbout = false
    @AppStorage(GalleryAppearance.accentColorKey)
    private var accentRGB = GalleryAppearance.defaultAccentRGB
    #if os(visionOS)
    @AppStorage(GalleryViewerPreferences.prefetchWindowKey)
    private var prefetchWindow = GalleryViewerPreferences.defaultPrefetchWindow
    @AppStorage(GalleryViewerPreferences.backwardPrefetchWindowKey)
    private var backwardPrefetchWindow = GalleryViewerPreferences.defaultBackwardPrefetchWindow
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Gallery Settings", systemImage: "gearshape")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.64))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(LensLabSecondaryButtonStyle())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        showingAbout = true
                    } label: {
                        Label("About Simple Vision Gallery", systemImage: "info.circle")
                    }
                    .buttonStyle(LensLabSecondaryButtonStyle())
                    .accessibilityIdentifier("gallery-open-about")

                    GallerySettingsSection(title: "Cinema Accent", subtitle: "Choose the color used by Cinema controls.") {
                        ColorPicker(
                            "Accent Color",
                            selection: Binding(
                                get: { GalleryAppearance.color(for: GalleryAppearance.validatedRGB(accentRGB)) },
                                set: { accentRGB = GalleryAppearance.rgbValue(for: $0) }
                            ),
                            supportsOpacity: false
                        )
                        .frame(minHeight: 60)
                        .accessibilityIdentifier("gallery-accent-color")

                        Button("Reset to Cinema Amber") {
                            accentRGB = GalleryAppearance.defaultAccentRGB
                        }
                        .buttonStyle(LensLabSecondaryButtonStyle())
                        .disabled(accentRGB == GalleryAppearance.defaultAccentRGB)
                        .accessibilityIdentifier("gallery-accent-reset")
                    }

                    #if os(visionOS)
                    GallerySettingsSection(title: "Slideshow", subtitle: "Prepare upcoming items while you browse.") {
                        Stepper(value: $prefetchWindow, in: GalleryViewerPreferences.prefetchWindowRange) {
                            HStack {
                                Text("Spatial prefetch window")
                                Spacer()
                                Text("\(prefetchWindow) items ahead")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.64))
                            }
                        }
                        .accessibilityIdentifier("svt-gallery-spatial-prefetch")

                        Stepper(value: $backwardPrefetchWindow,
                            in: GalleryViewerPreferences.backwardPrefetchWindowRange) {
                            HStack {
                                Text("Keep previous items")
                                Spacer()
                                Text("\(backwardPrefetchWindow) items behind")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.64))
                            }
                        }
                        .accessibilityIdentifier("svt-gallery-spatial-backward-prefetch")

                        Text("Photos are prepared as spatial scenes; videos are preloaded. Set either window to 0 to turn it off. All slideshow windows share a bounded preparation budget, so more open windows get smaller lookahead buffers.")
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #endif

                    GallerySettingsSection(title: "Album Visibility", subtitle: "Choose which albums appear in Gallery.") {
                        Toggle(
                            "Auto-hide empty albums",
                            isOn: Binding(
                                get: { manager.autoHideEmptyAlbums },
                                set: { manager.setAutoHideEmptyAlbums($0) }
                            )
                        )
                        .tint(LensLabTheme.cyan)
                        .accessibilityIdentifier("svt-gallery-auto-hide-empty")

                        Text("Empty albums appear in Hidden. Unhide an album to keep it visible, even when it is empty.")
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Albums you hide yourself stay hidden when auto-hide is off.")
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560)
        .background(LensLabTheme.card)
        .accessibilityIdentifier("svt-gallery-settings")
        .sheet(isPresented: $showingAbout) { GalleryAboutView() }
    }
}


private struct GallerySettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
            }
            .foregroundStyle(Color.white.opacity(0.64))
            .fixedSize(horizontal: false, vertical: true)
            content
                .foregroundStyle(LensLabTheme.ink)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lensLabCard()
    }
}
