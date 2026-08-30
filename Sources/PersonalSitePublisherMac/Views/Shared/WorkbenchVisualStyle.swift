import AppKit
import SwiftUI

private struct WorkbenchAdaptiveColor {
  typealias Components = (red: CGFloat, green: CGFloat, blue: CGFloat)

  let light: Components
  let dark: Components
  let lightHighContrast: Components?
  let darkHighContrast: Components?

  init(
    light: Components,
    dark: Components,
    lightHighContrast: Components? = nil,
    darkHighContrast: Components? = nil
  ) {
    self.light = light
    self.dark = dark
    self.lightHighContrast = lightHighContrast
    self.darkHighContrast = darkHighContrast
  }

  var color: Color {
    Color(nsColor: nsColor)
  }

  var nsColor: NSColor {
    NSColor(name: nil) { appearance in
      let components = self.components(for: appearance)
      return NSColor(
        red: components.red,
        green: components.green,
        blue: components.blue,
        alpha: 1
      )
    }
  }

  private func components(for appearance: NSAppearance) -> Components {
    let match = appearance.bestMatch(from: [
      .accessibilityHighContrastAqua,
      .accessibilityHighContrastDarkAqua,
      .aqua,
      .darkAqua,
    ])
    switch match {
    case .accessibilityHighContrastDarkAqua:
      return darkHighContrast ?? dark
    case .accessibilityHighContrastAqua:
      return lightHighContrast ?? light
    case .darkAqua:
      return dark
    default:
      return light
    }
  }
}

private enum WorkbenchSemanticPalette {
  static let primary = WorkbenchAdaptiveColor(
    light: (0.16, 0.39, 0.30),
    dark: (0.48, 0.78, 0.66),
    lightHighContrast: (0.08, 0.30, 0.21),
    darkHighContrast: (0.60, 0.90, 0.78)
  )
  static let success = WorkbenchAdaptiveColor(
    light: (0.22, 0.48, 0.22),
    dark: (0.50, 0.75, 0.48),
    lightHighContrast: (0.12, 0.37, 0.12),
    darkHighContrast: (0.62, 0.88, 0.60)
  )
  static let warning = WorkbenchAdaptiveColor(
    light: (0.68, 0.27, 0.03),
    dark: (0.90, 0.40, 0.10),
    lightHighContrast: (0.53, 0.18, 0.00),
    darkHighContrast: (1.00, 0.54, 0.20)
  )
  static let risk = WorkbenchAdaptiveColor(
    light: (0.64, 0.25, 0.33),
    dark: (0.91, 0.57, 0.64),
    lightHighContrast: (0.52, 0.12, 0.22),
    darkHighContrast: (1.00, 0.68, 0.74)
  )
}

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
  /// 对齐工程工具箱使用的默认“江南春”色板。
  static let jiangnanSpring = WorkbenchThemePalette(
    primary: WorkbenchSemanticPalette.primary.color,
    success: WorkbenchSemanticPalette.success.color,
    warning: WorkbenchSemanticPalette.warning.color,
    risk: WorkbenchSemanticPalette.risk.color,
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

  /// 产品识别色与主要操作色；导航选中态继续使用用户的系统强调色。
  static var brand: Color { `default`.primary }
  static var primary: Color { brand }
  static var success: Color { `default`.success }
  static var warning: Color { `default`.warning }
  static var risk: Color { `default`.risk }
  /// 信息状态色，既不表示进行中的操作，也不表示导航强调色。
  static let info = adaptive(
    light: (0.14, 0.42, 0.68),
    dark: (0.42, 0.68, 0.92),
    lightHighContrast: (0.05, 0.31, 0.56),
    darkHighContrast: (0.56, 0.79, 1.00)
  )
  /// 中性状态文本在所有外观下都遵循系统标签层级。
  static var neutral: Color { Color(nsColor: .secondaryLabelColor) }
  /// 进行中的工作使用偏冷色调，以区别于完成或成功状态。
  static let progress = adaptive(
    light: (0.16, 0.48, 0.44),
    dark: (0.38, 0.76, 0.69),
    lightHighContrast: (0.08, 0.36, 0.33),
    darkHighContrast: (0.48, 0.86, 0.78)
  )
  /// 主要控件在深色模式下需要更深的填充色，因为 macOS 会将标签渲染为白色。
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
  /// 语义主要填充色上的前景色；这些填充色在所有外观下都刻意保持较深。
  static var primaryActionForeground: Color { .white }
  /// 导航与选中态遵循用户的应用强调色偏好；品牌绿仅用于操作和状态。
  static var navigationSelection: Color { WorkbenchAccentPalette.selected().color }
  static var document: Color { `default`.document }
  static var documentForeground: Color { `default`.documentForeground }
  static var finance: Color { `default`.finance }
  static var inventory: Color { `default`.inventory }
  static var inventoryForeground: Color { `default`.inventoryForeground }

  private static func adaptive(
    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
    dark: (red: CGFloat, green: CGFloat, blue: CGFloat),
    lightHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)? = nil,
    darkHighContrast: (red: CGFloat, green: CGFloat, blue: CGFloat)? = nil
  ) -> Color {
    WorkbenchAdaptiveColor(
      light: light,
      dark: dark,
      lightHighContrast: lightHighContrast,
      darkHighContrast: darkHighContrast
    ).color
  }
}

enum WorkbenchThemeNSColor {
  static let primary = WorkbenchSemanticPalette.primary.nsColor
  static let success = WorkbenchSemanticPalette.success.nsColor
  static let warning = WorkbenchSemanticPalette.warning.nsColor
  static let risk = WorkbenchSemanticPalette.risk.nsColor
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
    // WCAG AAA 决策：高对比度模式下自动降级为系统纯色背景，确保文本与背景对比度达到最高标准 (>= 7:1)
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
  static let searchBar: CGFloat = 7
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

/// 共享空间节奏；名称描述布局角色，而不是单个调用点。
enum WorkbenchSpacing {
  /// 图标与紧密元素间距
  static let icon: CGFloat = 6
  /// 密集控件内容、紧凑行和小间距。
  static let control: CGFloat = 8
  /// 卡片内容和成组表单控件。
  static let card: CGFloat = 12
  /// 分区节奏和需要更多留白的编辑器边框。
  static let section: CGFloat = 14
  /// 标准内容内边距和分栏布局间距。
  static let content: CGFloat = 16
  /// 页面级内边距。
  static let page: CGFloat = 20
  /// 主要空状态和模态窗口标题。
  static let spacious: CGFloat = 24
}

/// The complete allow-list for custom workbench motion.
///
/// Navigation, hover, focus, pressing, and ambient activity intentionally have
/// no intent here. Those interactions should update immediately and rely on
/// native selection, focus, and progress affordances instead of custom motion.
enum WorkbenchMotionIntent: CaseIterable, Equatable, Sendable {
  case statusChange
  case drawerPresentation
  case taskCompletion
}

enum WorkbenchMotionStyle: Equatable, Sendable {
  case none
  case quickFade
  case drawerSlide
  case completionBounce
}

struct WorkbenchMotionPolicy: Equatable, Sendable {
  let reduceMotion: Bool

  func style(for intent: WorkbenchMotionIntent) -> WorkbenchMotionStyle {
    guard !reduceMotion else { return .none }

    switch intent {
    case .statusChange:
      return .quickFade
    case .drawerPresentation:
      return .drawerSlide
    case .taskCompletion:
      return .completionBounce
    }
  }
}

enum WorkbenchMotion {
  static func animation(
    for intent: WorkbenchMotionIntent,
    reduceMotion: Bool
  ) -> Animation? {
    switch WorkbenchMotionPolicy(reduceMotion: reduceMotion).style(for: intent) {
    case .none:
      return nil
    case .quickFade:
      return .easeOut(duration: 0.14)
    case .drawerSlide:
      return .easeInOut(duration: 0.20)
    case .completionBounce:
      return .spring(response: 0.20, dampingFraction: 0.70)
    }
  }

  static func drawerTransition(reduceMotion: Bool) -> AnyTransition {
    WorkbenchMotionPolicy(reduceMotion: reduceMotion).style(for: .drawerPresentation) == .none
      ? .identity
      : .move(edge: .trailing).combined(with: .opacity)
  }

  static func statusTransition(reduceMotion: Bool) -> AnyTransition {
    WorkbenchMotionPolicy(reduceMotion: reduceMotion).style(for: .statusChange) == .none
      ? .identity
      : .opacity
  }
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
}

enum WorkbenchSettingsMetrics {
  static let minimumWidth: CGFloat = 820
  static let idealWidth: CGFloat = 1_120
  static let minimumHeight: CGFloat = 560
  static let idealHeight: CGFloat = 760
  static let sidebarWidth: CGFloat = 204
  static let focusedContentWidth: CGFloat = 820
  static let detailedContentWidth: CGFloat = 820
}

enum WorkbenchOpacity {
  static let controlBackground = 0.45
  static let badgeBackground = 0.55
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
  /// 页面级分组保持透明；层级从实际内容卡片开始。
  static var page: AnyShapeStyle {
    AnyShapeStyle(Color.clear)
  }

  /// 主要卡片使用的唯一抬升内容表面。
  static var card: AnyShapeStyle {
    surface(opacity: 0.05)
  }

  /// 交互控件和紧凑徽标使用最强的中性表面。
  static var control: AnyShapeStyle {
    surface(opacity: 0.10)
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
        Text(String(localized: "已显示 \(visibleCount)/\(totalCount)"))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: WorkbenchSpacing.control)
        Button(
          showsAll ? String(localized: "收起") : String(localized: "显示全部")
        ) {
          showsAll.toggle()
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

/// 让自定义或普通按钮在 macOS 全键盘导航路径中保持可见。
/// 视图提供自定义背景时很容易丢失原生焦点环，因此由共享按钮样式绘制焦点环。
struct WorkbenchFocusRingButtonStyle: ButtonStyle {
  var cornerRadius: CGFloat = WorkbenchCornerRadius.control
  var lineWidth: CGFloat = 1.5

  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            isFocused ? Color.accentColor : Color.clear,
            lineWidth: isFocused ? lineWidth : 0
          )
      }
      .opacity(configuration.isPressed ? 0.82 : 1)
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

extension Font {
  /// 稳定的语义角色保持页面层级一致，同时保留用户的 macOS 字体大小和辅助功能设置。
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
}

extension View {
  func workbenchSettingsWindowSize() -> some View {
    frame(
      minWidth: WorkbenchSettingsMetrics.minimumWidth,
      idealWidth: WorkbenchSettingsMetrics.idealWidth,
      minHeight: WorkbenchSettingsMetrics.minimumHeight,
      idealHeight: WorkbenchSettingsMetrics.idealHeight
    )
  }

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
