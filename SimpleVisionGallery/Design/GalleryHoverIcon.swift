import SwiftUI

/// An icon-only control with a native hover label and a generous visionOS hit area.
struct GalleryHoverIcon: View {
    let symbol: String
    let title: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 60, height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .galleryHoverLabel(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? "")
        .hoverEffect(.highlight)
    }
}

private struct GalleryHoverLabelModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(visionOS)
        content
            .overlay(alignment: .bottom) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .offset(y: 40)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .hoverEffect { effect, active, _ in
                        effect.animation(.easeInOut(duration: 0.16).delay(active ? 0.7 : 0.1)) {
                            $0.opacity(active ? 1 : 0)
                        }
                    }
            }
            .hoverEffect(.highlight)
            .hoverEffectGroup()
            .help(title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
        #else
        content.help(title)
        #endif
    }
}

extension View {
    func galleryHoverLabel(_ title: String) -> some View {
        modifier(GalleryHoverLabelModifier(title: title))
    }
}
