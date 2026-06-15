import AppKit
import SwiftUI

enum CodexStatusPalette {
    private static let okRGB = (red: 0.02, green: 0.62, blue: 0.33)
    private static let warningRGB = (red: 0.76, green: 0.46, blue: 0.03)
    private static let dangerRGB = (red: 0.84, green: 0.25, blue: 0.15)
    private static let unavailableRGB = (red: 0.78, green: 0.16, blue: 0.22)

    static let ok = color(okRGB)
    static let warning = color(warningRGB)
    static let danger = color(dangerRGB)
    static let unavailable = color(unavailableRGB)
    static let neutral = Color.secondary

    static func color(for status: UsageStatus) -> Color {
        switch status {
        case .ok: return ok
        case .warning: return warning
        case .exceeded: return danger
        case .banned: return unavailable
        }
    }

    static func color(forUsedPercent usedPercent: Double) -> Color {
        if usedPercent >= 90 { return danger }
        if usedPercent >= 70 { return warning }
        return ok
    }

    static func nsColor(forUsedPercent usedPercent: Double) -> NSColor {
        if usedPercent >= 90 { return nsColor(dangerRGB) }
        if usedPercent >= 70 { return nsColor(warningRGB) }
        return nsColor(okRGB)
    }

    private static func color(_ rgb: (red: Double, green: Double, blue: Double)) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func nsColor(_ rgb: (red: Double, green: Double, blue: Double)) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }
}
