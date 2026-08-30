import AppKit
import SwiftUI

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
      .frame(minHeight: 120, idealHeight: 132, maxHeight: 140)

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
