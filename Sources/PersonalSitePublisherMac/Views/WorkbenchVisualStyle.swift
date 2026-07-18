import AppKit
import SwiftUI

struct WorkbenchThemePalette {
  let primary: Color
  let success: Color
  let warning: Color
  let risk: Color
  let document: Color
  let documentForeground: Color
  let finance: Color
  let inventory: Color
  let inventoryForeground: Color
  let people: Color
  let journal: Color
  let photo: Color
  let calculations: Color
  let quotation: Color
}

enum WorkbenchTheme {
  /// Mirrors the default “江南春” palette used by 工程工具箱.
  static let jiangnanSpring = WorkbenchThemePalette(
    primary: adaptive(
      light: (0.26, 0.48, 0.22),
      dark: (0.58, 0.78, 0.52),
      lightHighContrast: (0.16, 0.38, 0.12),
      darkHighContrast: (0.68, 0.88, 0.62)
    ),
    success: adaptive(
      light: (0.22, 0.48, 0.22),
      dark: (0.50, 0.75, 0.48),
      lightHighContrast: (0.12, 0.37, 0.12),
      darkHighContrast: (0.62, 0.88, 0.60)
    ),
    warning: adaptive(
      light: (0.68, 0.27, 0.03),
      dark: (0.90, 0.40, 0.10),
      lightHighContrast: (0.53, 0.18, 0.00),
      darkHighContrast: (1.00, 0.54, 0.20)
    ),
    risk: adaptive(
      light: (0.64, 0.25, 0.33),
      dark: (0.91, 0.57, 0.64),
      lightHighContrast: (0.52, 0.12, 0.22),
      darkHighContrast: (1.00, 0.68, 0.74)
    ),
    document: adaptive(light: (0.55, 0.66, 0.73), dark: (0.65, 0.75, 0.80)),
    documentForeground: adaptive(light: (0.22, 0.39, 0.48), dark: (0.65, 0.75, 0.80)),
    finance: adaptive(light: (0.83, 0.66, 0.33), dark: (0.88, 0.72, 0.44)),
    inventory: adaptive(light: (0.61, 0.55, 0.71), dark: (0.70, 0.64, 0.78)),
    inventoryForeground: adaptive(light: (0.38, 0.31, 0.50), dark: (0.70, 0.64, 0.78)),
    people: adaptive(light: (0.49, 0.65, 0.65), dark: (0.60, 0.74, 0.74)),
    journal: adaptive(light: (0.78, 0.72, 0.59), dark: (0.85, 0.79, 0.67)),
    photo: adaptive(light: (0.72, 0.44, 0.42), dark: (0.80, 0.54, 0.52)),
    calculations: adaptive(light: (0.42, 0.62, 0.71), dark: (0.54, 0.72, 0.80)),
    quotation: adaptive(light: (0.77, 0.61, 0.48), dark: (0.84, 0.69, 0.56))
  )

  static let `default` = jiangnanSpring

  static var primary: Color { `default`.primary }
  static var success: Color { `default`.success }
  static var warning: Color { `default`.warning }
  static var risk: Color { `default`.risk }
  /// Active work uses a cooler hue so it remains distinct from completed/success states.
  static let progress = adaptive(
    light: (0.16, 0.48, 0.44),
    dark: (0.38, 0.76, 0.69),
    lightHighContrast: (0.08, 0.36, 0.33),
    darkHighContrast: (0.48, 0.86, 0.78)
  )
  /// Prominent controls need a darker dark-mode fill because macOS renders their labels in white.
  static let primaryActionFill = adaptive(
    light: (0.26, 0.48, 0.22),
    dark: (0.22, 0.42, 0.18),
    lightHighContrast: (0.16, 0.38, 0.12),
    darkHighContrast: (0.16, 0.34, 0.12)
  )
  static let warningActionFill = adaptive(
    light: (0.68, 0.27, 0.03),
    dark: (0.58, 0.24, 0.04),
    lightHighContrast: (0.53, 0.18, 0.00),
    darkHighContrast: (0.48, 0.16, 0.00)
  )
  /// Navigation and selection follow the user's macOS accent; brand green remains reserved for actions and status.
  static var navigationSelection: Color { Color(nsColor: .controlAccentColor) }
  static var document: Color { `default`.document }
  static var documentForeground: Color { `default`.documentForeground }
  static var finance: Color { `default`.finance }
  static let financeForeground = adaptive(
    light: (0.46, 0.32, 0.08),
    dark: (0.88, 0.72, 0.44),
    lightHighContrast: (0.36, 0.23, 0.03),
    darkHighContrast: (0.96, 0.82, 0.54)
  )
  static var inventory: Color { `default`.inventory }
  static var inventoryForeground: Color { `default`.inventoryForeground }

  private static func adaptive(
    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
    dark: (red: CGFloat, green: CGFloat, blue: CGFloat),
    lightHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)? = nil,
    darkHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
          .accessibilityHighContrastAqua,
          .accessibilityHighContrastDarkAqua,
          .aqua,
          .darkAqua,
        ])
        let components: (red: CGFloat, green: CGFloat, blue: CGFloat)
        switch match {
        case .accessibilityHighContrastDarkAqua:
          components = darkHighContrast ?? dark
        case .accessibilityHighContrastAqua:
          components = lightHighContrast ?? light
        case .darkAqua:
          components = dark
        default:
          components = light
        }
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

enum WorkbenchThemeNSColor {
  static let primary = adaptive(
    light: (0.26, 0.48, 0.22),
    dark: (0.58, 0.78, 0.52),
    lightHighContrast: (0.16, 0.38, 0.12),
    darkHighContrast: (0.68, 0.88, 0.62)
  )
  static let success = adaptive(
    light: (0.22, 0.48, 0.22),
    dark: (0.50, 0.75, 0.48),
    lightHighContrast: (0.12, 0.37, 0.12),
    darkHighContrast: (0.62, 0.88, 0.60)
  )
  static let warning = adaptive(
    light: (0.68, 0.27, 0.03),
    dark: (0.90, 0.40, 0.10),
    lightHighContrast: (0.53, 0.18, 0.00),
    darkHighContrast: (1.00, 0.54, 0.20)
  )
  static let risk = adaptive(
    light: (0.64, 0.25, 0.33),
    dark: (0.91, 0.57, 0.64),
    lightHighContrast: (0.52, 0.12, 0.22),
    darkHighContrast: (1.00, 0.68, 0.74)
  )

  private static func adaptive(
    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
    dark: (red: CGFloat, green: CGFloat, blue: CGFloat),
    lightHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)? = nil,
    darkHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)? = nil
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      let match = appearance.bestMatch(from: [
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .aqua,
        .darkAqua,
      ])
      let components: (red: CGFloat, green: CGFloat, blue: CGFloat)
      switch match {
      case .accessibilityHighContrastDarkAqua:
        components = darkHighContrast ?? dark
      case .accessibilityHighContrastAqua:
        components = lightHighContrast ?? light
      case .darkAqua:
        components = dark
      default:
        components = light
      }
      return NSColor(
        red: components.red,
        green: components.green,
        blue: components.blue,
        alpha: 1
      )
    }
  }
}

enum WorkbenchCornerRadius {
  static let chartBar: CGFloat = 3
  static let control: CGFloat = 6
  static let card: CGFloat = 8
}

enum WorkbenchPageMetrics {
  static let horizontalPadding: CGFloat = 20
  static let verticalPadding: CGFloat = 20
  static let readingWidth: CGFloat = 980
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
  /// Page-level grouping. Keep this nearly flat so nested sections do not become grey blocks.
  static var page: AnyShapeStyle {
    surface(opacity: 0.025)
  }

  /// The single elevated content surface used for primary cards.
  static var card: AnyShapeStyle {
    surface(opacity: 0.055)
  }

  /// Interactive controls and compact badges use the strongest neutral surface.
  static var control: AnyShapeStyle {
    surface(opacity: 0.085)
  }

  // Compatibility aliases intentionally map the previous five surface names to
  // the three levels above. This prevents older views from reintroducing extra
  // grey layers while they are migrated incrementally.
  static var subtle: AnyShapeStyle {
    page
  }

  static var panel: AnyShapeStyle {
    card
  }

  static var badge: AnyShapeStyle {
    control
  }

  static var codeBlock: AnyShapeStyle {
    control
  }

  private static func surface(opacity: Double) -> AnyShapeStyle {
    AnyShapeStyle(Color(nsColor: .labelColor).opacity(opacity))
  }
}

struct WorkbenchListDisclosureFooter: View {
  let visibleCount: Int
  let totalCount: Int
  @Binding var showsAll: Bool

  var body: some View {
    if totalCount > visibleCount || showsAll {
      HStack(spacing: 8) {
        Text("已显示 \(visibleCount)/\(totalCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button(
          showsAll ? String(localized: "收起") : String(localized: "显示全部")
        ) {
          withAnimation(.easeInOut(duration: 0.16)) {
            showsAll.toggle()
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("列表显示进度")
      .accessibilityValue("已显示 \(visibleCount) 项，共 \(totalCount) 项")
    }
  }
}

extension Font {
  static let workbenchCardTitle: Font = .callout.weight(.semibold)
  static let workbenchMetricValue: Font = .title3.weight(.semibold)
  static let workbenchPath: Font = .caption.monospaced()
}

extension View {
  func workbenchPageLayout(
    maxWidth: CGFloat = WorkbenchPageMetrics.readingWidth
  ) -> some View {
    padding(.horizontal, WorkbenchPageMetrics.horizontalPadding)
      .padding(.vertical, WorkbenchPageMetrics.verticalPadding)
      .frame(maxWidth: maxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  func workbenchProminentActionStyle(
    tint: Color = WorkbenchTheme.primaryActionFill
  ) -> some View {
    buttonStyle(.borderedProminent)
      .tint(tint)
  }
}
