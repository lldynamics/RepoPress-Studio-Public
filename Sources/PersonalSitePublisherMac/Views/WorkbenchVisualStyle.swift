import AppKit
import SwiftUI

struct WorkbenchThemePalette {
  let primary: Color
  let success: Color
  let warning: Color
  let risk: Color
  let document: Color
  let finance: Color
  let inventory: Color
  let people: Color
  let journal: Color
  let photo: Color
  let calculations: Color
  let quotation: Color
}

enum WorkbenchTheme {
  /// Mirrors the default “江南春” palette used by 工程工具箱.
  static let jiangnanSpring = WorkbenchThemePalette(
    primary: adaptive(light: (0.48, 0.69, 0.42), dark: (0.58, 0.78, 0.52)),
    success: adaptive(light: (0.35, 0.62, 0.35), dark: (0.50, 0.75, 0.48)),
    warning: adaptive(light: (0.90, 0.40, 0.10), dark: (0.90, 0.40, 0.10)),
    risk: adaptive(light: (0.91, 0.57, 0.64), dark: (0.91, 0.57, 0.64)),
    document: adaptive(light: (0.55, 0.66, 0.73), dark: (0.65, 0.75, 0.80)),
    finance: adaptive(light: (0.83, 0.66, 0.33), dark: (0.88, 0.72, 0.44)),
    inventory: adaptive(light: (0.61, 0.55, 0.71), dark: (0.70, 0.64, 0.78)),
    people: adaptive(light: (0.49, 0.65, 0.65), dark: (0.60, 0.74, 0.74)),
    journal: adaptive(light: (0.78, 0.72, 0.59), dark: (0.85, 0.79, 0.67)),
    photo: adaptive(light: (0.72, 0.44, 0.42), dark: (0.80, 0.54, 0.52)),
    calculations: adaptive(light: (0.42, 0.62, 0.71), dark: (0.54, 0.72, 0.80)),
    quotation: adaptive(light: (0.77, 0.61, 0.48), dark: (0.84, 0.69, 0.56))
  )

  static let `default` = jiangnanSpring

  private static func adaptive(
    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
    dark: (red: CGFloat, green: CGFloat, blue: CGFloat)
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          red: components.red,
          green: components.green,
          blue: components.blue,
          alpha: 1
        )
      }
    )
  }
}

enum WorkbenchCornerRadius {
  static let chartBar: CGFloat = 3
  static let control: CGFloat = 6
  static let card: CGFloat = 8
}

enum WorkbenchOpacity {
  static let subtleBackground = 0.20
  static let panelBackground = 0.28
  static let cardBackground = 0.35
  static let controlBackground = 0.45
  static let badgeBackground = 0.55
  static let codeBlockBackground = 0.06
  static let selectionBackground = 0.12
  static let accentBackground = 0.16
  static let noticeBackground = 0.10
  static let warningBackground = 0.08
  static let separator = 0.70
  static let chartSecondary = 0.28
  static let chartPrimary = 0.60
  static let chartEmphasis = 0.70
}

enum WorkbenchBackgroundStyle {
  static var subtle: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.subtleBackground))
  }

  static var panel: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.panelBackground))
  }

  static var card: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.cardBackground))
  }

  static var control: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.controlBackground))
  }

  static var badge: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.badgeBackground))
  }

  static var codeBlock: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.codeBlockBackground))
  }
}

extension Font {
  static let workbenchCardTitle: Font = .callout.weight(.semibold)
  static let workbenchMetricValue: Font = .title3.weight(.semibold)
  static let workbenchPath: Font = .caption.monospaced()
}
