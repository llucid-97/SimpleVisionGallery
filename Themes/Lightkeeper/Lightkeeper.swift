// Target audience: app developers. Host-target SwiftUI/Metal theme; no app models or persistence.
import SwiftUI

public enum LightkeeperSurfaceRole: Sendable {
    case canvas, raised, control
    fileprivate var intensity: Float {
        switch self { case .canvas: 0.75; case .raised: 0.60; case .control: 0.48 }
    }
}

public struct LightkeeperTokens: Sendable {
    public var accent: Color
    public var onAccent: Color
    public var foreground: Color
    public var secondaryForeground: Color
    public var canvas: Color
    public var raised: Color
    public var control: Color

    public init(accent: Color = Color(red: 1, green: 197.0 / 255, blue: 105.0 / 255),
        onAccent: Color = .black, foreground: Color = .white,
        secondaryForeground: Color = .white.opacity(0.76),
        canvas: Color = Color(red: 0.055, green: 0.064, blue: 0.070),
        raised: Color = Color(red: 0.105, green: 0.115, blue: 0.122),
        control: Color = Color(red: 0.14, green: 0.15, blue: 0.155)) {
        self.accent = accent; self.onAccent = onAccent
        self.foreground = foreground; self.secondaryForeground = secondaryForeground
        self.canvas = canvas; self.raised = raised; self.control = control
    }

    fileprivate func base(_ role: LightkeeperSurfaceRole) -> Color {
        switch role { case .canvas: canvas; case .raised: raised; case .control: control }
    }
}

private struct LightkeeperTokensKey: EnvironmentKey { static let defaultValue = LightkeeperTokens() }
private struct LightkeeperTransparencyKey: EnvironmentKey { static let defaultValue = false }
private struct LightkeeperMotionKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    var lightkeeperTokens: LightkeeperTokens {
        get { self[LightkeeperTokensKey.self] }
        set { self[LightkeeperTokensKey.self] = newValue }
    }
    var lightkeeperReduceTransparency: Bool {
        get { self[LightkeeperTransparencyKey.self] }
        set { self[LightkeeperTransparencyKey.self] = newValue }
    }
    var lightkeeperReduceMotion: Bool {
        get { self[LightkeeperMotionKey.self] }
        set { self[LightkeeperMotionKey.self] = newValue }
    }
}

public extension View {
    func lightkeeperTheme(_ tokens: LightkeeperTokens = LightkeeperTokens()) -> some View {
        environment(\.lightkeeperTokens, tokens).tint(tokens.accent).foregroundStyle(tokens.foreground)
    }
    /// Overrides may reduce effects; they never disable the system accessibility preference.
    func lightkeeperReduceEffects(transparency: Bool = false, motion: Bool = false) -> some View {
        environment(\.lightkeeperReduceTransparency, transparency)
            .environment(\.lightkeeperReduceMotion, motion)
    }
    func lightkeeperSurface(_ role: LightkeeperSurfaceRole = .raised, cornerRadius: CGFloat = 16) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                LightkeeperSurface(role: role, cornerRadius: cornerRadius)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 5, y: 8)
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 1, y: 2)
            }
    }
    func lightkeeperBackdrop(cornerRadius: CGFloat = 24) -> some View {
        modifier(LightkeeperBackdropModifier(cornerRadius: cornerRadius))
    }
}

/// Static warm key/cool fill/bevel/occlusion approximation on the backing only.
public struct LightkeeperSurface: View {
    public let role: LightkeeperSurfaceRole
    public let cornerRadius: CGFloat
    @Environment(\.lightkeeperTokens) private var tokens
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.lightkeeperReduceTransparency) private var previewReduceTransparency

    public init(role: LightkeeperSurfaceRole = .raised, cornerRadius: CGFloat = 16) {
        self.role = role; self.cornerRadius = cornerRadius
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if systemReduceTransparency || previewReduceTransparency {
                shape.fill(tokens.base(role))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                shape.fill(tokens.base(role))
                    .visualEffect { content, geometry in
                        content.colorEffect(Shader(function: ShaderFunction(library: .default,
                            name: "lightkeeperSurfaceLight"), arguments: [
                                .float2(geometry.size), .float(cornerRadius), .float(role.intensity)
                            ]))
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LightkeeperBackdropModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.lightkeeperTokens) private var tokens
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.lightkeeperReduceTransparency) private var previewReduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if systemReduceTransparency || previewReduceTransparency {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tokens.raised)
            }
        } else {
            #if os(visionOS)
            content
                .background { LightkeeperSurface(cornerRadius: cornerRadius).opacity(0.55) }
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            #else
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.regularMaterial)
                    .overlay { LightkeeperSurface(cornerRadius: cornerRadius).opacity(0.55) }
            }
            #endif
        }
    }
}

public struct LightkeeperSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lightkeeperTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lightkeeperReduceMotion) private var previewReduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let reduceMotion = systemReduceMotion || previewReduceMotion
        configuration.label.font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? tokens.foreground : tokens.secondaryForeground)
            .padding(.horizontal, 18).frame(minWidth: 60, minHeight: 60)
            .lightkeeperSurface(.control, cornerRadius: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.35 : 0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.8)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .hoverEffect(.highlight)
    }
}

public struct LightkeeperPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lightkeeperTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lightkeeperReduceMotion) private var previewReduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? tokens.onAccent : tokens.secondaryForeground)
            .padding(.horizontal, 18).padding(.vertical, 10).frame(minWidth: 60, minHeight: 60)
            .background(isEnabled ? tokens.accent : tokens.secondaryForeground.opacity(0.34),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tokens.foreground.opacity(isEnabled ? 0.25 : 0.10), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && isEnabled && !(systemReduceMotion || previewReduceMotion) ? 0.98 : 1)
            .hoverEffect(.highlight)
    }
}

public struct LightkeeperSearchField: View {
    @Binding private var query: String
    private let placeholder: String
    private let isSearching: Bool
    private let identifier: String?
    @Environment(\.lightkeeperTokens) private var tokens
    public init(query: Binding<String>, placeholder: String = "Search", isSearching: Bool = false,
        accessibilityIdentifier: String? = nil) {
        _query = query; self.placeholder = placeholder
        self.isSearching = isSearching; identifier = accessibilityIdentifier
    }
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(tokens.secondaryForeground)
            TextField(placeholder, text: $query,
                prompt: Text(placeholder).foregroundStyle(tokens.secondaryForeground))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if isSearching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .foregroundStyle(tokens.secondaryForeground).frame(width: 60, height: 60)
            }
        }
        .font(.body).padding(.horizontal, 16).frame(minHeight: 68)
        .lightkeeperSurface(.control, cornerRadius: 18)
        .accessibilityIdentifier(identifier ?? "")
    }
}

public struct LightkeeperCard<Content: View>: View {
    private let content: Content
    private let role: LightkeeperSurfaceRole
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    public init(role: LightkeeperSurfaceRole = .raised, cornerRadius: CGFloat = 24, padding: CGFloat = 24,
        @ViewBuilder content: () -> Content) {
        self.role = role; self.cornerRadius = cornerRadius; self.padding = padding; self.content = content()
    }
    public var body: some View {
        content.padding(padding).lightkeeperSurface(role, cornerRadius: cornerRadius)
    }
}

public struct LightkeeperRow<Accessory: View>: View {
    private let title: String
    private let detail: String?
    private let symbol: String?
    private let accessory: Accessory
    @Environment(\.lightkeeperTokens) private var tokens
    public init(_ title: String, detail: String? = nil, symbol: String? = nil,
        @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.accessory = accessory()
    }
    public var body: some View {
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).frame(width: 24) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                if let detail { Text(detail).font(.callout).foregroundStyle(tokens.secondaryForeground) }
            }
            Spacer(minLength: 12)
            accessory
        }
        .frame(minHeight: 60)
    }
}

public struct LightkeeperActionLabel: View {
    private let title: String
    private let symbol: String
    public init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    public var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}

/// Two content rows; all behavior, current item identity and privacy covers belong to the host.
public struct LightkeeperDock<Primary: View, Secondary: View>: View {
    private let width: CGFloat
    private let primary: Primary
    private let secondary: Secondary
    public init(width: CGFloat, @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.width = width; self.primary = primary(); self.secondary = secondary()
    }
    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 32) { primary }.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
            Divider().overlay(Color.white.opacity(0.08))
            secondary
        }
        .padding(10).frame(width: width - 16)
        .lightkeeperBackdrop(cornerRadius: 22).padding(8)
    }
}
