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
  /// Informational status that is neither an in-progress operation nor a navigation accent.
  static let info = adaptive(
    light: (0.14, 0.42, 0.68),
    dark: (0.42, 0.68, 0.92),
    lightHighContrast: (0.05, 0.31, 0.56),
    darkHighContrast: (0.56, 0.79, 1.00)
  )
  /// Neutral status copy follows the system label hierarchy in every appearance.
  static var neutral: Color { Color(nsColor: .secondaryLabelColor) }
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
  /// Foreground for semantic prominent fills. These fills are intentionally dark in every appearance.
  static var primaryActionForeground: Color { .white }
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
  static let horizontalPadding = WorkbenchSpacing.page
  static let verticalPadding = WorkbenchSpacing.page
  static let readingWidth: CGFloat = 980
  static let operationalSplitMinimumWidth: CGFloat = 1_080
  static let operationalContextWidth: CGFloat = 320

  static func usesOperationalSplit(for availableWidth: CGFloat) -> Bool {
    availableWidth >= operationalSplitMinimumWidth
  }
}

/// Shared spatial rhythm. Names describe layout roles instead of individual call sites.
enum WorkbenchSpacing {
  /// Dense control contents, compact rows, and small gaps.
  static let control: CGFloat = 8
  /// Card contents and grouped form controls.
  static let card: CGFloat = 12
  /// Section rhythm and editor chrome that need a little more breathing room.
  static let section: CGFloat = 14
  /// Standard content insets and split-layout gaps.
  static let content: CGFloat = 16
  /// Page-level insets.
  static let page: CGFloat = 20
  /// Prominent empty states and modal headers.
  static let spacious: CGFloat = 24
}

enum WorkbenchMotion {
  static let quick = Animation.easeOut(duration: 0.12)
  static let standard = Animation.easeInOut(duration: 0.16)
  static let deliberate = Animation.easeInOut(duration: 0.20)
  static let hoverSpring = Animation.spring(response: 0.25, dampingFraction: 0.75)
  static let gentleSpring = Animation.spring(response: 0.25, dampingFraction: 0.80)
  static let emphasisSpring = Animation.spring(response: 0.20, dampingFraction: 0.70)
  static let ambientPulse = Animation.easeInOut(duration: 1.35).repeatForever(autoreverses: true)
}

enum WorkbenchSheetMetrics {
  struct Size {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat
  }

  enum Preset {
    case compact
    case detail
    case wide
    case full

    fileprivate var size: Size {
      switch self {
      case .compact:
        Size(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
      case .detail:
        Size(minWidth: 680, idealWidth: 780, minHeight: 520, idealHeight: 640)
      case .wide:
        Size(minWidth: 760, idealWidth: 900, minHeight: 580, idealHeight: 700)
      case .full:
        Size(minWidth: 900, idealWidth: 1_120, minHeight: 620, idealHeight: 760)
      }
    }
  }

  /// Upper bound for hosts that calculate a sheet height from the visible screen.
  static let maxHeightRatio: CGFloat = 0.90
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

private enum WorkbenchGlassBorder {
  static func gradient(for colorScheme: ColorScheme) -> LinearGradient {
    let colors: [Color]
    if colorScheme == .dark {
      colors = [
        Color.white.opacity(0.10),
        Color.white.opacity(0.04),
      ]
    } else {
      colors = [
        Color.black.opacity(0.08),
        Color.black.opacity(0.03),
      ]
    }

    return LinearGradient(
      colors: colors,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

private struct WorkbenchGlassSurfaceModifier<SurfaceShape: InsettableShape>: ViewModifier {
  let material: Material
  let shape: SurfaceShape

  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(material, in: shape)
      .overlay {
        shape.strokeBorder(
          WorkbenchGlassBorder.gradient(for: colorScheme),
          lineWidth: 1
        )
        .allowsHitTesting(false)
      }
  }
}

private struct WorkbenchGlassContainerModifier: ViewModifier {
  let material: Material
  let drawsBorder: Bool

  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(material)
      .overlay {
        if drawsBorder {
          Rectangle()
            .strokeBorder(
              WorkbenchGlassBorder.gradient(for: colorScheme),
              lineWidth: 1
            )
            .allowsHitTesting(false)
        }
      }
  }
}

extension View {
  func workbenchGlassSurface<S: InsettableShape>(
    material: Material,
    in shape: S
  ) -> some View {
    modifier(WorkbenchGlassSurfaceModifier(material: material, shape: shape))
  }

  func workbenchGlassContainer(
    material: Material = .thinMaterial,
    drawsBorder: Bool = true
  ) -> some View {
    modifier(
      WorkbenchGlassContainerModifier(
        material: material,
        drawsBorder: drawsBorder
      )
    )
  }
}

struct WorkbenchModalSurface<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .workbenchGlassContainer(material: .regularMaterial)
  }
}

struct WorkbenchListDisclosureFooter: View {
  let visibleCount: Int
  let totalCount: Int
  @Binding var showsAll: Bool

  var body: some View {
    if totalCount > visibleCount || showsAll {
      HStack(spacing: WorkbenchSpacing.control) {
        Text("已显示 \(visibleCount)/\(totalCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: WorkbenchSpacing.control)
        Button(
          showsAll ? String(localized: "收起") : String(localized: "显示全部")
        ) {
          withAnimation(WorkbenchMotion.standard) {
            showsAll.toggle()
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("列表显示进度")
      .accessibilityValue(String(localized: "已显示 \(visibleCount) 项，共 \(totalCount) 项"))
    }
  }
}

/// Keeps custom/plain buttons visible in the macOS full-keyboard navigation path.
/// Native focus rings are easy to lose when a view supplies its own background,
/// so the ring is rendered by the shared button style instead.
struct WorkbenchFocusRingButtonStyle: ButtonStyle {
  var cornerRadius: CGFloat = WorkbenchCornerRadius.control

  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            isFocused ? Color.accentColor : Color.clear,
            lineWidth: isFocused ? 2 : 0
          )
      }
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(WorkbenchMotion.quick, value: configuration.isPressed)
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
      HStack(alignment: .top, spacing: WorkbenchSpacing.content) {
        primary
          .frame(maxWidth: .infinity, alignment: .topLeading)
        context
          .frame(width: WorkbenchPageMetrics.operationalContextWidth, alignment: .topLeading)
      }
    } else {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
        context
        primary
      }
    }
  }
}

enum WorkbenchPadding {
  /// 8px: 用于小控件、微标签、紧凑按钮内边距
  static let compact = WorkbenchSpacing.control
  /// 12px: 用于容器卡片、表单 Section、弹窗组标准内边距
  static let card = WorkbenchSpacing.card
  /// 16px: 用于普通内容容器内边距
  static let content = WorkbenchSpacing.content
  /// 20px: 用于页面顶层边距
  static let page = WorkbenchSpacing.page
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
  func workbenchSheetSize(_ preset: WorkbenchSheetMetrics.Preset) -> some View {
    let size = preset.size
    return frame(
      minWidth: size.minWidth,
      idealWidth: size.idealWidth,
      minHeight: size.minHeight,
      idealHeight: size.idealHeight
    )
  }

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
