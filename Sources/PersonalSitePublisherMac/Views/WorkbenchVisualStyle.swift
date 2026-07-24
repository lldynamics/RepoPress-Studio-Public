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
      light: (0.16, 0.39, 0.30),
      dark: (0.48, 0.78, 0.66),
      lightHighContrast: (0.08, 0.30, 0.21),
      darkHighContrast: (0.60, 0.90, 0.78)
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

  /// Product identity and primary actions. Navigation selection remains the user's system accent.
  static var brand: Color { `default`.primary }
  static var primary: Color { brand }
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
    light: (0.16, 0.39, 0.30),
    dark: (0.14, 0.34, 0.25),
    lightHighContrast: (0.08, 0.30, 0.21),
    darkHighContrast: (0.09, 0.28, 0.19)
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
    light: (0.16, 0.39, 0.30),
    dark: (0.48, 0.78, 0.66),
    lightHighContrast: (0.08, 0.30, 0.21),
    darkHighContrast: (0.60, 0.90, 0.78)
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

enum WorkbenchWritingSurface {
  static func color(usesWarmPaper: Bool) -> Color {
    Color(nsColor: nsColor(usesWarmPaper: usesWarmPaper))
  }

  static func nsColor(usesWarmPaper: Bool) -> NSColor {
    usesWarmPaper ? warmPaper : .textBackgroundColor
  }

  private static let warmPaper = NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [
      .accessibilityHighContrastAqua,
      .accessibilityHighContrastDarkAqua,
      .aqua,
      .darkAqua,
    ]) {
    case .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua:
      return .textBackgroundColor
    case .darkAqua:
      return NSColor(srgbRed: 0.125, green: 0.129, blue: 0.114, alpha: 1)
    default:
      return NSColor(srgbRed: 0.984, green: 0.980, blue: 0.969, alpha: 1)
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
  static let operationalSplitMinimumWidth: CGFloat = 1_080
  static let operationalContextWidth: CGFloat = 320

  static func usesOperationalSplit(for availableWidth: CGFloat) -> Bool {
    availableWidth >= operationalSplitMinimumWidth
  }
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
  /// Page-level grouping stays transparent; hierarchy starts with actual content cards.
  static var page: AnyShapeStyle {
    AnyShapeStyle(Color.clear)
  }

  /// The single elevated content surface used for primary cards.
  static var card: AnyShapeStyle {
    surface(opacity: 0.05)
  }

  /// Interactive controls and compact badges use the strongest neutral surface.
  static var control: AnyShapeStyle {
    surface(opacity: 0.10)
  }

  // Compatibility aliases intentionally map the previous five surface names to
  // the three levels above. This prevents older views from reintroducing extra
  // grey layers while they are migrated incrementally.
  static var subtle: AnyShapeStyle {
    card
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

struct WorkbenchOperationalSplitLayout<Primary: View, Context: View>: View {
  let usesSplitLayout: Bool
  private let primary: Primary
  private let context: Context

  init(
    usesSplitLayout: Bool,
    @ViewBuilder primary: () -> Primary,
    @ViewBuilder context: () -> Context
  ) {
    self.usesSplitLayout = usesSplitLayout
    self.primary = primary()
    self.context = context()
  }

  @ViewBuilder
  var body: some View {
    if usesSplitLayout {
      HStack(alignment: .top, spacing: 16) {
        primary
          .frame(maxWidth: .infinity, alignment: .topLeading)
        context
          .frame(width: WorkbenchPageMetrics.operationalContextWidth, alignment: .topLeading)
      }
    } else {
      VStack(alignment: .leading, spacing: 16) {
        context
        primary
      }
    }
  }
}

extension Font {
  /// Stable semantic roles keep page hierarchy consistent while preserving the
  /// user's macOS text-size and accessibility settings.
  static let workbenchPageTitle: Font = .title2.weight(.semibold)
  static let workbenchPageSubtitle: Font = .callout
  static let workbenchSectionTitle: Font = .headline
  static let workbenchItemTitle: Font = .callout.weight(.medium)
  static let workbenchBody: Font = .body
  static let workbenchSupporting: Font = .callout
  static let workbenchMetadata: Font = .caption
  static let workbenchButtonLabel: Font = .callout.weight(.medium)

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

  func workbenchOperationalPageLayout() -> some View {
    workbenchPageLayout(maxWidth: .infinity)
  }

  func workbenchProminentActionStyle(
    tint: Color = WorkbenchTheme.primaryActionFill
  ) -> some View {
    buttonStyle(.borderedProminent)
      .tint(tint)
  }
}
