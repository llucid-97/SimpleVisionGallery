import SwiftUI

struct GallerySettingsView: View {
    @ObservedObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingAbout = false
    @AppStorage(GalleryAppearance.accentColorKey)
    private var accentRGB = GalleryAppearance.defaultAccentRGB
    #if os(visionOS)
    @AppStorage(GalleryViewerPreferences.pairedYawKey)
    private var pairedYaw = GalleryViewerPreferences.defaultPairedYaw
    @AppStorage(GalleryViewerPreferences.pairedPitchKey)
    private var pairedPitch = GalleryViewerPreferences.defaultPairedPitch
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
                    .foregroundStyle(LensLabTheme.ink)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(LensLabSecondaryButtonStyle())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GallerySettingsSection(title: "Appearance") {
                        HStack(spacing: 16) {
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

                            Button("Reset") {
                                accentRGB = GalleryAppearance.defaultAccentRGB
                            }
                            .buttonStyle(LensLabSecondaryButtonStyle())
                            .disabled(accentRGB == GalleryAppearance.defaultAccentRGB)
                            .accessibilityIdentifier("gallery-accent-reset")
                        }
                    }

                    Divider()
                    #if os(visionOS)
                    GallerySettingsSection(title: "Slideshow") {
                        Stepper(value: $prefetchWindow, in: GalleryViewerPreferences.prefetchWindowRange) {
                            HStack {
                                Text("Prepare ahead")
                                Spacer()
                                Text("\(prefetchWindow) items")
                                    .monospacedDigit()
                                    .foregroundStyle(LensLabTheme.mutedInk)
                            }
                        }
                        .accessibilityIdentifier("svt-gallery-spatial-prefetch")

                        Stepper(value: $backwardPrefetchWindow,
                            in: GalleryViewerPreferences.backwardPrefetchWindowRange) {
                            HStack {
                                Text("Keep behind")
                                Spacer()
                                Text("\(backwardPrefetchWindow) items")
                                    .monospacedDigit()
                                    .foregroundStyle(LensLabTheme.mutedInk)
                            }
                        }
                        .accessibilityIdentifier("svt-gallery-spatial-backward-prefetch")

                        DisclosureGroup("Preparation details") {
                            Text("Photos are prepared as spatial scenes; videos are preloaded. Set either window to 0 to turn it off. All slideshow windows share a bounded preparation budget, so more open windows get smaller lookahead buffers.")
                                .font(.callout)
                                .foregroundStyle(LensLabTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    #endif

                    #if os(visionOS)
                    Divider()
                    GallerySettingsSection(title: "Dual View") {
                        HStack {
                            Text("Inward yaw")
                            Spacer()
                            Text("\(Int(pairedYaw))°").monospacedDigit()
                                .foregroundStyle(LensLabTheme.mutedInk)
                        }
                        Slider(value: $pairedYaw, in: GalleryViewerPreferences.pairedYawRange, step: 1)
                            .accessibilityLabel("Inward yaw")
                            .accessibilityValue("\(Int(pairedYaw)) degrees")
                            .accessibilityIdentifier("gallery-dual-yaw")

                        HStack {
                            Text("Pitch")
                            Spacer()
                            Text("\(Int(pairedPitch))°").monospacedDigit()
                                .foregroundStyle(LensLabTheme.mutedInk)
                        }
                        Slider(value: $pairedPitch, in: GalleryViewerPreferences.pairedPitchRange, step: 1)
                            .accessibilityLabel("Pitch")
                            .accessibilityValue("\(Int(pairedPitch)) degrees")
                            .accessibilityIdentifier("gallery-dual-pitch")

                        Button("Reset Angles") {
                            pairedYaw = GalleryViewerPreferences.defaultPairedYaw
                            pairedPitch = GalleryViewerPreferences.defaultPairedPitch
                        }
                        .buttonStyle(LensLabSecondaryButtonStyle())
                        .disabled(pairedYaw == GalleryViewerPreferences.defaultPairedYaw &&
                            pairedPitch == GalleryViewerPreferences.defaultPairedPitch)
                        .accessibilityIdentifier("gallery-dual-angles-reset")
                    }
                    #endif

                    Divider()
                    GallerySettingsSection(title: "Album Visibility") {
                        Toggle(
                            "Auto-hide empty albums",
                            isOn: Binding(
                                get: { manager.autoHideEmptyAlbums },
                                set: { manager.setAutoHideEmptyAlbums($0) }
                            )
                        )
                        .tint(LensLabTheme.cyan)
                        .accessibilityIdentifier("svt-gallery-auto-hide-empty")

                        DisclosureGroup("Visibility details") {
                            Text("While unlocked, empty albums appear in Hidden. Unhide one to keep it visible. Albums with no Photos items are hidden while the vault is locked. Albums you hide yourself stay hidden when auto-hide is off.")
                                .font(.callout)
                                .foregroundStyle(LensLabTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.visible)
            Divider()
            Button { showingAbout = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                    Text("About Simple Vision Gallery")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16).frame(minHeight: 52)
                .galleryLightSurface(role: .control, cornerRadius: 16)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gallery-open-about")
            .hoverEffect(.highlight)
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560)
        .galleryLightBackdrop(cornerRadius: 24)
        .accessibilityIdentifier("svt-gallery-settings")
        .blur(radius: showingAbout ? 9 : 0)
        .sheet(isPresented: $showingAbout) { GalleryAboutView() }
    }
}


private struct GallerySettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(LensLabTheme.ink)
                .padding(.leading, 12)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            content
                .foregroundStyle(LensLabTheme.ink)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
