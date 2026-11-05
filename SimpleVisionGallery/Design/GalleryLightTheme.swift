import SwiftUI

private struct GalleryLightReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}
private struct GalleryLightReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    /// Optional previews can reduce effects; these never disable a system accessibility preference.
    var galleryLightReduceTransparency: Bool {
        get { self[GalleryLightReduceTransparencyKey.self] }
        set { self[GalleryLightReduceTransparencyKey.self] = newValue }
    }
    var galleryLightReduceMotion: Bool {
        get { self[GalleryLightReduceMotionKey.self] }
        set { self[GalleryLightReduceMotionKey.self] = newValue }
    }
}

/// Roles share one fixed warm key and cool fill, while keeping large planes subdued.
enum GalleryLightRole {
    case canvas
    case raised
    case control

    fileprivate var base: Color {
        switch self {
        case .canvas: Color(red: 0.055, green: 0.064, blue: 0.070)
        case .raised: Color(red: 0.105, green: 0.115, blue: 0.122)
        case .control: Color(red: 0.14, green: 0.15, blue: 0.155)
        }
    }

    fileprivate var intensity: Float {
        switch self {
        case .canvas: 0.75
        case .raised: 0.60
        case .control: 0.48
        }
    }
}

/// A backdrop tint for surfaces only. Keep photographs and all text above this layer.
struct GalleryLightSurface: View {
    var role: GalleryLightRole = .raised
    var cornerRadius: CGFloat = 16

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.galleryLightReduceTransparency) private var previewReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || previewReduceTransparency }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let intensity = role.intensity
        Group {
            if reduceTransparency {
                shape.fill(role.base)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                shape.fill(role.base)
                    .visualEffect { content, geometry in
                        content.colorEffect(Shader(
                        function: ShaderFunction(library: .default, name: "galleryLightPlane"),
                        arguments: [.float2(geometry.size), .float(cornerRadius), .float(intensity)]
                    ))
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

struct GalleryLightSurfaceModifier: ViewModifier {
    var role: GalleryLightRole
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                GalleryLightSurface(role: role, cornerRadius: cornerRadius)
                    .shadow(color: Color.black.opacity(0.25), radius: 12, x: 5, y: 8)
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 1, y: 2)
            }
    }
}

extension View {
    /// Applies lighting behind content. The modifier never shades its text or imagery.
    func galleryLightSurface(role: GalleryLightRole = .raised, cornerRadius: CGFloat = 16) -> some View {
        modifier(GalleryLightSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }

    /// Native blurred backdrop for menus and sheets; foreground content stays sharp.
    func galleryLightBackdrop(cornerRadius: CGFloat = 20) -> some View {
        background {
            GalleryLightBackdrop(cornerRadius: cornerRadius)
        }
    }
}

/// System glass blurs the physical scene behind free-standing visionOS ornaments.
private struct GalleryOrnamentBackdropModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.galleryLightReduceTransparency) private var previewReduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if systemReduceTransparency || previewReduceTransparency {
            content.galleryLightBackdrop(cornerRadius: cornerRadius)
        } else {
            content
                .background { GalleryLightSurface(role: .raised, cornerRadius: cornerRadius).opacity(0.55) }
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func galleryOrnamentBackdrop(cornerRadius: CGFloat) -> some View {
        modifier(GalleryOrnamentBackdropModifier(cornerRadius: cornerRadius))
    }
}

private struct GalleryLightBackdrop: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.galleryLightReduceTransparency) private var previewReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || previewReduceTransparency }

    var body: some View {
        Group {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius).fill(GalleryLightRole.raised.base)
            } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    GalleryLightSurface(role: .raised, cornerRadius: cornerRadius).opacity(0.78)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 22, x: 8, y: 12)
            }
        }
        .accessibilityHidden(true)
    }
}

struct GalleryLightButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.galleryLightReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.50))
            .padding(.horizontal, 18)
            .frame(minWidth: 60, minHeight: 60)
            .galleryLightSurface(role: .control, cornerRadius: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.35 : 0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.65)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .hoverEffect(.highlight)
    }
}

/// Shared viewer controls retain44pt targets with a compact32pt gap inside the dock.
struct GalleryViewerControlBar<Content: View>: View {
    var presentsBackdrop = true
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if presentsBackdrop { row.galleryLightBackdrop(cornerRadius: 22) }
            else { row }
        }
    }

    private var row: some View {
        HStack(spacing: presentsBackdrop ? 52 : 32) { content }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.top, presentsBackdrop ? 18 : 0)
    }
}

/// One shared dock keeps browsing nearest the image, with session actions underneath.
struct GalleryViewerDock<Browse: View, Details: View>: View {
    let width: CGFloat
    @ViewBuilder var browse: Browse
    @ViewBuilder var details: Details

    var body: some View {
        VStack(spacing: 8) {
            browse
            Divider().overlay(Color.white.opacity(0.08))
            details
        }
        .padding(10)
        .frame(width: width - 16)
        .galleryOrnamentBackdrop(cornerRadius: 22)
        .padding(8)
    }
}

/// Small visible action captions retain the native viewer's established hit-area geometry.
struct GalleryViewerActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
