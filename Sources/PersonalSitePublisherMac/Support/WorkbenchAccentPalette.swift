import AppKit
import SwiftUI

enum WorkbenchAccentPalette: String, CaseIterable, Identifiable {
  static let storageKey = "workbenchAccentPaletteV1"

  case system
  case emerald
  case blue
  case violet
  case amber
  case rose
  case graphite

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return String(localized: "跟随 macOS")
    case .emerald:
      return String(localized: "薄荷绿 Emerald")
    case .blue:
      return String(localized: "海湾蓝 Blue")
    case .violet:
      return String(localized: "紫罗兰 Violet")
    case .amber:
      return String(localized: "琥珀黄 Amber")
    case .rose:
      return String(localized: "玫瑰红 Rose")
    case .graphite:
      return String(localized: "石墨灰 Graphite")
    }
  }

  var color: Color {
    switch self {
    case .system:
      return Color(nsColor: .controlAccentColor)
    case .emerald:
      return Self.adaptive(
        light: (0.04, 0.56, 0.42),
        dark: (0.36, 0.82, 0.66),
        lightHighContrast: (0.00, 0.43, 0.31),
        darkHighContrast: (0.49, 0.93, 0.78)
      )
    case .blue:
      return Self.adaptive(
        light: (0.12, 0.47, 0.84),
        dark: (0.38, 0.68, 0.96),
        lightHighContrast: (0.02, 0.34, 0.68),
        darkHighContrast: (0.54, 0.78, 1.00)
      )
    case .violet:
      return Self.adaptive(
        light: (0.46, 0.27, 0.82),
        dark: (0.72, 0.59, 0.95),
        lightHighContrast: (0.34, 0.16, 0.68),
        darkHighContrast: (0.82, 0.72, 1.00)
      )
    case .amber:
      return Self.adaptive(
        light: (0.72, 0.40, 0.00),
        dark: (0.94, 0.67, 0.29),
        lightHighContrast: (0.57, 0.29, 0.00),
        darkHighContrast: (1.00, 0.77, 0.39)
      )
    case .rose:
      return Self.adaptive(
        light: (0.75, 0.22, 0.38),
        dark: (0.94, 0.48, 0.61),
        lightHighContrast: (0.61, 0.10, 0.27),
        darkHighContrast: (1.00, 0.61, 0.72)
      )
    case .graphite:
      return Self.adaptive(
        light: (0.42, 0.44, 0.47),
        dark: (0.72, 0.74, 0.77),
        lightHighContrast: (0.28, 0.30, 0.33),
        darkHighContrast: (0.84, 0.86, 0.89)
      )
    }
  }

  static func resolved(rawValue: String?) -> WorkbenchAccentPalette {
    rawValue.flatMap(WorkbenchAccentPalette.init(rawValue:)) ?? .system
  }

  static func selected(in defaults: UserDefaults = .standard) -> WorkbenchAccentPalette {
    resolved(rawValue: defaults.string(forKey: storageKey))
  }

  private static func adaptive(
    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
    dark: (red: CGFloat, green: CGFloat, blue: CGFloat),
    lightHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat),
    darkHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let components: (red: CGFloat, green: CGFloat, blue: CGFloat)
        switch appearance.bestMatch(from: [
          .accessibilityHighContrastAqua,
          .accessibilityHighContrastDarkAqua,
          .aqua,
          .darkAqua,
        ]) {
        case .accessibilityHighContrastDarkAqua:
          components = darkHighContrast
        case .accessibilityHighContrastAqua:
          components = lightHighContrast
        case .darkAqua:
          components = dark
        default:
          components = light
        }
        return NSColor(
          srgbRed: components.red,
          green: components.green,
          blue: components.blue,
          alpha: 1
        )
      }
    )
  }
}
