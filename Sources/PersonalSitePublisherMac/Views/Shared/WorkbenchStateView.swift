import AppKit
import SwiftUI

/// Semantic workspace surfaces stay distinct without borrowing the accent or
/// status palettes. The writing role delegates to the established paper
/// implementation so AppKit text views and SwiftUI containers remain equal.
enum WorkbenchSurface {
  static let sidebar = WorkbenchAdaptiveColor(
    light: (0.945, 0.950, 0.945),
    dark: (0.105, 0.115, 0.108),
    lightHighContrast: (0.905, 0.915, 0.905),
    darkHighContrast: (0.055, 0.065, 0.058)
  ).color

  static let inspector = WorkbenchAdaptiveColor(
    light: (0.965, 0.968, 0.963),
    dark: (0.125, 0.132, 0.126),
    lightHighContrast: (0.925, 0.930, 0.922),
    darkHighContrast: (0.070, 0.076, 0.071)
  ).color

  static let groupedCard = WorkbenchAdaptiveColor(
    light: (0.990, 0.990, 0.985),
    dark: (0.165, 0.172, 0.166),
    lightHighContrast: (1.000, 1.000, 1.000),
    darkHighContrast: (0.205, 0.215, 0.207)
  ).color

  static func writingPaper(usesWarmPaper: Bool) -> Color {
    WorkbenchWritingSurface.color(usesWarmPaper: usesWarmPaper)
  }
}

/// The compact status vocabulary shared by article rows and future grouped
/// cards. Accent color is intentionally absent: tags communicate state only.
enum WorkbenchStatusTagKind: Hashable {
  case draft
  case ready
  case published
  case localOnly
  case unsynced
  case publishFailed
  case alerts(Int)

  var title: String {
    switch self {
    case .draft:
      return String(localized: "草稿")
    case .ready:
      return String(localized: "待发布")
    case .published:
      return String(localized: "已发布")
    case .localOnly:
      return String(localized: "仅本地")
    case .unsynced:
      return String(localized: "同步异常")
    case .publishFailed:
      return String(localized: "发布失败")
    case .alerts(let count):
      return String(localized: "\(count) 项问题")
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .draft: return "doc.text"
    case .ready: return "checkmark.circle"
    case .published: return "checkmark.seal"
    case .localOnly: return "internaldrive"
    case .unsynced: return "arrow.triangle.2.circlepath"
    case .publishFailed: return "xmark.octagon"
    case .alerts: return "exclamationmark.triangle"
    }
  }

  fileprivate var tone: WorkbenchStatusTagTone {
    switch self {
    case .draft: return .neutral
    case .ready: return .information
    case .published: return .success
    case .localOnly: return .neutral
    case .unsynced: return .warning
    case .publishFailed: return .risk
    case .alerts: return .warning
    }
  }

  fileprivate var identifier: String {
    switch self {
    case .draft: return "draft"
    case .ready: return "ready"
    case .published: return "published"
    case .localOnly: return "local-only"
    case .unsynced: return "unsynced"
    case .publishFailed: return "publish-failed"
    case .alerts: return "alerts"
    }
  }
}

private enum WorkbenchStatusTagTone {
  case neutral
  case information
  case success
  case warning
  case risk

  var color: Color {
    switch self {
    case .neutral: return WorkbenchTheme.neutral
    case .information: return WorkbenchTheme.info
    case .success: return WorkbenchTheme.success
    case .warning: return WorkbenchTheme.warning
    case .risk: return WorkbenchTheme.risk
    }
  }
}

struct WorkbenchStatusTag: View {
  let kind: WorkbenchStatusTagKind

  var body: some View {
    Label(kind.title, systemImage: kind.systemImage)
      .labelStyle(.titleAndIcon)
      .font(.workbenchMetadata.weight(.medium))
      .foregroundStyle(kind.tone.color)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, WorkbenchSpacing.icon)
      .padding(.vertical, 2)
      .background(kind.tone.color.opacity(0.10), in: Capsule())
      .overlay {
        Capsule()
          .strokeBorder(kind.tone.color.opacity(0.22), lineWidth: 1)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(kind.title)
      .accessibilityIdentifier("workbench-status-tag-\(kind.identifier)")
  }
}

struct WorkbenchStateView: View {
  let presentation: WorkbenchStatePresentation
  let density: WorkbenchStateDensity
  let titleOverride: LocalizedStringKey?
  let detail: LocalizedStringKey?
  let actions: WorkbenchStateActions
  @State private var lastAnnouncedIdentity: String?

  init(
    presentation: WorkbenchStatePresentation,
    density: WorkbenchStateDensity = .fullPage,
    titleOverride: LocalizedStringKey? = nil,
    detail: LocalizedStringKey? = nil,
    actions: WorkbenchStateActions = .none
  ) {
    self.presentation = presentation
    self.density = density
    self.titleOverride = titleOverride
    self.detail = detail
    self.actions = actions
  }

  var body: some View {
    stateLayout
      .accessibilityElement(children: hasActions ? .contain : .combine)
      .modifier(
        WorkbenchStateProgressAccessibilityModifier(
          progress: presentation.loadingProgress
        )
      )
      .onAppear(perform: announceIfNeeded)
      .onChange(of: presentation.announcementIdentity) { _, _ in
        announceIfNeeded()
      }
  }

  @ViewBuilder
  private var stateLayout: some View {
    switch density {
    case .fullPage:
      VStack(spacing: WorkbenchSpacing.card) {
        stateIcon(size: 38)
        stateCopy(
          titleFont: .headline,
          messageFont: .callout,
          messageWidth: 360,
          alignment: .center
        )
        actionControls(primaryStyle: .prominent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .compactPane:
      VStack(spacing: WorkbenchSpacing.control) {
        stateIcon(size: 28)
        stateCopy(
          titleFont: .workbenchCardTitle,
          messageFont: .workbenchSupporting,
          messageWidth: 300,
          alignment: .center
        )
        actionControls(primaryStyle: .bordered)
      }
      .padding(.vertical, WorkbenchSpacing.card)
      .frame(maxWidth: .infinity)
      // No height cap: a fixed maximum truncated longer explanations.
      .frame(minHeight: 120)

    case .inline:
      HStack(alignment: .top, spacing: WorkbenchSpacing.control) {
        stateIcon(size: 17)
          .frame(width: 20)
        stateCopy(
          titleFont: .workbenchItemTitle,
          messageFont: .workbenchMetadata,
          messageWidth: nil,
          alignment: .leading
        )
        Spacer(minLength: 4)
        actionControls(primaryStyle: .borderless)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func stateIcon(size: CGFloat) -> some View {
    if case .loading = presentation.kind {
      if let progress = presentation.loadingProgress {
        ProgressView(value: progress)
          .progressViewStyle(.circular)
          .tint(presentation.tone.color)
          .frame(width: size, height: size)
          .accessibilityHidden(true)
      } else {
        ProgressView()
          .controlSize(size >= 28 ? .regular : .small)
          .tint(presentation.tone.color)
          .frame(width: size, height: size)
          .accessibilityHidden(true)
      }
    } else {
      Image(systemName: presentation.systemImage)
        .font(.system(size: size))
        .foregroundStyle(presentation.tone.color)
        .accessibilityHidden(true)
    }
  }

  private func stateCopy(
    titleFont: Font,
    messageFont: Font,
    messageWidth: CGFloat?,
    alignment: TextAlignment
  ) -> some View {
    VStack(alignment: alignment == .leading ? .leading : .center, spacing: 3) {
      stateTitle(font: titleFont)
      if let reason = presentation.formattedReason {
        stateMessage(
          Text(verbatim: reason),
          font: messageFont,
          width: messageWidth,
          alignment: alignment
        )
        .textSelection(.enabled)
      }
      if let verbatimDetail = presentation.verbatimDetail {
        stateMessage(
          Text(verbatim: verbatimDetail),
          font: messageFont,
          width: messageWidth,
          alignment: alignment
        )
        .textSelection(.enabled)
      }
      if let detail {
        stateMessage(
          Text(detail),
          font: messageFont,
          width: messageWidth,
          alignment: alignment
        )
      }
    }
  }

  @ViewBuilder
  private func stateTitle(font: Font) -> some View {
    if let titleOverride {
      Text(titleOverride)
        .font(font)
    } else {
      Text(presentation.title)
        .font(font)
    }
  }

  private func stateMessage(
    _ text: Text,
    font: Font,
    width: CGFloat?,
    alignment: TextAlignment
  ) -> some View {
    text
      .font(font)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(alignment)
      .frame(maxWidth: width, alignment: alignment == .leading ? .leading : .center)
  }

  private var hasActions: Bool {
    actions.primary != nil || actions.secondary != nil
  }

  private func announceIfNeeded() {
    guard presentation.announcementPolicy.shouldAnnounce,
      lastAnnouncedIdentity != presentation.announcementIdentity
    else { return }

    let policy = AccessibleStatusAnnouncementPolicy(
      severity: presentation.announcementSeverity,
      announcesNonUrgentStatus: true,
      movesAccessibilityFocusForUrgentStatus: false
    )
    guard policy.shouldAnnounce, let priority = policy.priority else { return }
    lastAnnouncedIdentity = presentation.announcementIdentity

    let message = presentation.announcementText
    DispatchQueue.main.async {
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: message,
          .priority: appKitPriority(for: priority).rawValue,
        ]
      )
    }
  }

  private func appKitPriority(
    for priority: AccessibleStatusAnnouncementPriority
  ) -> NSAccessibilityPriorityLevel {
    switch priority {
    case .low:
      return .low
    case .medium:
      return .medium
    case .high:
      return .high
    }
  }

  @ViewBuilder
  private func actionControls(primaryStyle: WorkbenchStateActionStyle) -> some View {
    if actions.primary != nil || actions.secondary != nil {
      HStack(spacing: WorkbenchSpacing.control) {
        if let primary = actions.primary {
          stateAction(primary, style: primaryStyle)
        }
        if let secondary = actions.secondary {
          stateAction(secondary, style: .bordered)
        }
      }
    }
  }

  @ViewBuilder
  private func stateAction(
    _ action: WorkbenchStateAction,
    style: WorkbenchStateActionStyle
  ) -> some View {
    Button(role: action.role, action: action.action) {
      Label(action.title, systemImage: action.systemImage)
    }
    .disabled(!action.isEnabled)
    .modifier(WorkbenchStateActionStyleModifier(style: style))
  }
}

private struct WorkbenchStateProgressAccessibilityModifier: ViewModifier {
  let progress: Double?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let progress {
      content.accessibilityValue(
        Text(progress, format: .percent.precision(.fractionLength(0)))
      )
    } else {
      content
    }
  }
}

enum WorkbenchStateDensity {
  case fullPage
  case compactPane
  case inline
}

private enum WorkbenchStateActionStyle {
  case prominent
  case bordered
  case borderless
}

private struct WorkbenchStateActionStyleModifier: ViewModifier {
  let style: WorkbenchStateActionStyle

  @ViewBuilder
  func body(content: Content) -> some View {
    switch style {
    case .prominent:
      content.workbenchProminentActionStyle()
    case .bordered:
      content
        .buttonStyle(.bordered)
        .controlSize(.small)
    case .borderless:
      content
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
  }
}

extension WorkbenchStateTone {
  fileprivate var color: Color {
    switch self {
    case .neutral:
      return .secondary
    case .progress:
      return WorkbenchTheme.progress
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .risk:
      return WorkbenchTheme.risk
    }
  }
}
