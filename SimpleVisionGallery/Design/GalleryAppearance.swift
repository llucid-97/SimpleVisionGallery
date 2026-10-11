import SwiftUI
import UIKit
import CoreFoundation

/// Stores the Cinema accent as a portable packed sRGB integer (`0xRRGGBB`).
enum GalleryAppearance {
    static let accentColorKey = "gallery.appearance.accentRGB.v1"
    static let defaultAccentRGB = 0xFFC569

    private static let darkCardRGB = 0x202A33

    /// The selected accent, adjusted only when needed for readable use on Cinema's dark cards.
    static var accent: Color {
        accent(for: savedRGB)
    }

    /// The saved packed sRGB color, or the Cinema amber when no valid value is stored.
    static var savedRGB: Int {
        guard let number = UserDefaults.standard.object(forKey: accentColorKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(number.stringValue),
              isValidRGB(value) else {
            return defaultAccentRGB
        }
        return value
    }

    static func color(for rgb: Int) -> Color {
        let value = isValidRGB(rgb) ? rgb : defaultAccentRGB
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Converts a ColorPicker color to packed sRGB. Unsupported color spaces use Cinema amber.
    static func rgbValue(for color: Color) -> Int {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return defaultAccentRGB
        }
        let r = Int((min(max(red, 0), 1) * 255).rounded())
        let g = Int((min(max(green, 0), 1) * 255).rounded())
        let b = Int((min(max(blue, 0), 1) * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    /// Ensures at least 4.5:1 contrast against Cinema's dark-card reference surface.
    static func accent(for rgb: Int) -> Color {
        color(from: accessibleComponents(rgb))
    }

    private static func accessibleComponents(_ rgb: Int) -> [Double] {
        let components = normalizedComponents(rgb)
        let background = normalizedComponents(darkCardRGB)
        guard contrast(components, background) < 4.5 else { return components }

        // Find the smallest blend toward white that reaches the contrast target.
        var low = 0.0
        var high = 1.0
        for _ in 0..<16 {
            let amount = (low + high) / 2
            let candidate = components.map { $0 + (1 - $0) * amount }
            if contrast(candidate, background) >= 4.5 {
                high = amount
            } else {
                low = amount
            }
        }
        return components.map { $0 + (1 - $0) * high }
    }

    /// Picks readable black or white text for controls filled with the selected accent.
    static func accentForeground(for rgb: Int) -> Color {
        let components = accessibleComponents(rgb)
        let luminance = relativeLuminance(components)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .black : .white
    }

    static var accentForeground: Color {
        accentForeground(for: savedRGB)
    }

    static func validatedRGB(_ value: Int) -> Int {
        isValidRGB(value) ? value : defaultAccentRGB
    }

    private static func isValidRGB(_ value: Int) -> Bool {
        (0...0xFFFFFF).contains(value)
    }

    private static func normalizedComponents(_ rgb: Int) -> [Double] {
        let value = validatedRGB(rgb)
        return [Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255]
    }

    private static func color(from components: [Double]) -> Color {
        Color(.sRGB, red: components[0], green: components[1], blue: components[2], opacity: 1)
    }

    private static func contrast(_ foreground: [Double], _ background: [Double]) -> Double {
        let first = relativeLuminance(foreground)
        let second = relativeLuminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(_ components: [Double]) -> Double {
        let linear = components.map { component -> Double in
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
