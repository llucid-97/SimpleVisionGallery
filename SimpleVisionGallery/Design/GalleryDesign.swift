//
//  LensLabTheme.swift
//  simple_vision_tools
//
//  Created by Codex Prism on 07/05/2026.
//

import SwiftUI

enum LensLabTheme {
    static let cyan = Color(red: 34 / 255, green: 184 / 255, blue: 173 / 255)
    static let orange = Color(red: 240 / 255, green: 120 / 255, blue: 34 / 255)
    static let blue = Color(red: 45 / 255, green: 159 / 255, blue: 232 / 255)
    static let green = Color(red: 51 / 255, green: 181 / 255, blue: 102 / 255)
    static let red = Color(red: 214 / 255, green: 74 / 255, blue: 74 / 255)

    static let ink = Color(red: 38 / 255, green: 35 / 255, blue: 31 / 255)
    static let mutedInk = Color(red: 110 / 255, green: 103 / 255, blue: 93 / 255)
    static let card = Color(red: 245 / 255, green: 241 / 255, blue: 234 / 255)
    static let cardLine = Color(red: 207 / 255, green: 198 / 255, blue: 184 / 255)

    static let shellWarm = Color(red: 181 / 255, green: 172 / 255, blue: 157 / 255)
    static let shellShadow = Color(red: 88 / 255, green: 78 / 255, blue: 65 / 255)
    static let sidebarTop = Color(red: 64 / 255, green: 61 / 255, blue: 56 / 255)
    static let sidebarBottom = Color(red: 45 / 255, green: 43 / 255, blue: 39 / 255)
    static let previewSurface = Color(red: 33 / 255, green: 32 / 255, blue: 29 / 255)
}

struct LensLabCardModifier: ViewModifier {
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(LensLabTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LensLabTheme.cardLine.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: LensLabTheme.shellShadow.opacity(0.08), radius: 16, y: 8)
    }
}

extension View {
    func lensLabCard(radius: CGFloat = 8) -> some View {
        modifier(LensLabCardModifier(radius: radius))
    }
}

struct LensLabPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? LensLabTheme.cyan : LensLabTheme.mutedInk.opacity(0.34))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(isEnabled ? 0.25 : 0.1), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LensLabSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? LensLabTheme.ink : LensLabTheme.mutedInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isEnabled ? 0.42 : 0.18))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LensLabTheme.cardLine.opacity(isEnabled ? 0.9 : 0.35), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.62)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LensLabToolHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var status: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LensLabTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(LensLabTheme.mutedInk)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if let status {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LensLabTheme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.44), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(LensLabTheme.cardLine.opacity(0.7), lineWidth: 1)
                    }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lensLabCard()
    }
}

struct LensLabSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LensLabTheme.ink)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(LensLabTheme.mutedInk)
                        .lineLimit(2)
                }
            }

            content
        }
        .foregroundStyle(LensLabTheme.ink)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lensLabCard()
    }
}
