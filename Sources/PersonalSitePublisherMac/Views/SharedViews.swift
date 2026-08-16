import AppKit
import PublishingWorkbenchCore
import SwiftUI

private struct WorkbenchTruncatedIdentityModifier: ViewModifier {
  let value: String
  let lineLimit: Int

  func body(content: Content) -> some View {
    content
      .lineLimit(lineLimit)
      .truncationMode(.middle)
      .help(value)
      .contextMenu {
        Button(action: copyValue) {
          Label("复制完整内容", systemImage: "doc.on.doc")
        }
      }
      .accessibilityAction(named: Text("复制完整内容"), copyValue)
  }

  private func copyValue() {
    ClipboardWriter.copy(
      value,
      successMessage: String(localized: "已复制到剪贴板。")
    ) { message in
      EditorAccessibilityAnnouncementCenter.announce(message)
    }
  }
}

extension View {
  /// Applies the shared treatment for titles, paths, URLs, and identifiers that may truncate.
  func workbenchTruncatedIdentity(_ value: String, lineLimit: Int = 1) -> some View {
    modifier(WorkbenchTruncatedIdentityModifier(value: value, lineLimit: lineLimit))
  }
}

/// Gives repository paths an independently readable primary label without hiding the full path.
struct WorkbenchPathIdentity: View {
  let path: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(fileName)
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
      if fileName != path {
        Text(path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
    .workbenchTruncatedIdentity(path)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(fileName)
    .accessibilityValue(path)
  }

  private var fileName: String {
    path
      .split(whereSeparator: { $0 == "/" || $0 == "\\" })
      .last
      .map(String.init)
      ?? path
  }
}

struct MetricTile: View {
  let title: String
  let value: String
  let systemImage: String
  let tint: Color?

  init(title: String, value: String, systemImage: String, tint: Color? = nil) {
    self.title = title
    self.value = value
    self.systemImage = systemImage
    self.tint = tint
  }

  init(title: String, value: String, semantic: MetricTileSemantic) {
    self.title = title
    self.value = value
    self.systemImage = semantic.systemImage
    self.tint = semantic.color
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(LocalizedStringKey(title), systemImage: systemImage)
        .font(.workbenchSupporting)
        .foregroundStyle(tint ?? .secondary)
      Text(value)
        .font(.workbenchMetricValue)
        .lineLimit(1)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(LocalizedStringKey(title)))
    .accessibilityValue(value)
  }
}

/// Keeps the three primary status metrics aligned on normal windows, then reflows only when space is tight.
struct PrimaryStatusMetricGrid<Content: View>: View {
  private let spacing: CGFloat
  private let content: () -> Content

  init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
    self.spacing = spacing
    self.content = content
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(minimum: 160), spacing: spacing),
          count: 3
        ),
        spacing: spacing
      ) {
        content()
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: spacing)],
        spacing: spacing
      ) {
        content()
      }
    }
  }
}

enum MetricTileSemantic {
  case blocking
  case warning
  case passed
  case progress
  case neutral

  var systemImage: String {
    switch self {
    case .blocking:
      return "stop.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .passed:
      return "checkmark.seal.fill"
    case .progress:
      return "arrow.trianglehead.2.clockwise"
    case .neutral:
      return "circle.grid.2x2"
    }
  }

  var color: Color {
    switch self {
    case .blocking:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .passed:
      return WorkbenchTheme.success
    case .progress:
      return WorkbenchTheme.progress
    case .neutral:
      return .secondary
    }
  }
}

struct SeverityBadge: View {
  let severity: PreflightSeverity

  var body: some View {
    Label(severity.localizedDisplayName, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(color)
      .labelStyle(.titleAndIcon)
  }

  private var systemImage: String {
    switch severity {
    case .error:
      return "xmark.octagon"
    case .warning:
      return "exclamationmark.triangle"
    case .info:
      return "checkmark.circle"
    }
  }

  private var color: Color {
    switch severity {
    case .error:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return WorkbenchTheme.success
    }
  }
}

enum EmptyStateDensity {
  case fullPage
  case compactPane
  case inline
}

struct EmptyStateView: View {
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let systemImage: String
  let density: EmptyStateDensity
  let actionTitle: LocalizedStringKey?
  let actionSystemImage: String
  let action: (() -> Void)?

  init(
    title: LocalizedStringKey,
    message: LocalizedStringKey,
    systemImage: String,
    density: EmptyStateDensity = .fullPage,
    actionTitle: LocalizedStringKey? = nil,
    actionSystemImage: String = "arrow.right.circle",
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.density = density
    self.actionTitle = actionTitle
    self.actionSystemImage = actionSystemImage
    self.action = action
  }

  @ViewBuilder
  var body: some View {
    switch density {
    case .fullPage:
      VStack(spacing: 12) {
        emptyStateIcon(size: 38)
        emptyStateCopy(
          titleFont: .headline,
          messageFont: .callout,
          messageWidth: 360,
          alignment: .center
        )
        if let actionTitle, let action {
          Button(action: action) {
            Label(actionTitle, systemImage: actionSystemImage)
          }
          .workbenchProminentActionStyle()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .compactPane:
      VStack(spacing: 9) {
        emptyStateIcon(size: 28)
        emptyStateCopy(
          titleFont: .workbenchCardTitle,
          messageFont: .workbenchSupporting,
          messageWidth: 300,
          alignment: .center
        )
        if let actionTitle, let action {
          Button(action: action) {
            Label(actionTitle, systemImage: actionSystemImage)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity)
      .frame(minHeight: 120, idealHeight: 132, maxHeight: 140)

    case .inline:
      HStack(alignment: .top, spacing: 9) {
        emptyStateIcon(size: 17)
          .frame(width: 20)
        emptyStateCopy(
          titleFont: .workbenchItemTitle,
          messageFont: .workbenchMetadata,
          messageWidth: nil,
          alignment: .leading
        )
        Spacer(minLength: 4)
        if let actionTitle, let action {
          Button(action: action) {
            Label(actionTitle, systemImage: actionSystemImage)
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func emptyStateIcon(size: CGFloat) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: size))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  private func emptyStateCopy(
    titleFont: Font,
    messageFont: Font,
    messageWidth: CGFloat?,
    alignment: TextAlignment
  ) -> some View {
    VStack(alignment: alignment == .leading ? .leading : .center, spacing: 3) {
      Text(title)
        .font(titleFont)
      Text(message)
        .font(messageFont)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(alignment)
        .frame(maxWidth: messageWidth, alignment: alignment == .leading ? .leading : .center)
    }
  }
}

extension AccessibleStatusSeverity {
  fileprivate var systemImage: String {
    switch self {
    case .info:
      return "info.circle"
    case .success:
      return "checkmark.circle"
    case .warning:
      return "exclamationmark.triangle"
    case .error:
      return "xmark.octagon"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .info:
      return WorkbenchTheme.progress
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .error:
      return WorkbenchTheme.risk
    }
  }
}

extension AccessibleStatusAnnouncementPriority {
  fileprivate var appKitPriority: NSAccessibilityPriorityLevel {
    switch self {
    case .low:
      return .low
    case .medium:
      return .medium
    case .high:
      return .high
    }
  }
}

struct AccessibleStatusMessage: View {
  let message: String
  let severity: AccessibleStatusSeverity
  let announcesNonUrgentStatus: Bool
  let movesAccessibilityFocusForUrgentStatus: Bool
  @AccessibilityFocusState private var isAccessibilityFocused: Bool

  init(
    message: String,
    severity: AccessibleStatusSeverity,
    announcesNonUrgentStatus: Bool = false,
    movesAccessibilityFocusForUrgentStatus: Bool = true
  ) {
    self.message = message
    self.severity = severity
    self.announcesNonUrgentStatus = announcesNonUrgentStatus
    self.movesAccessibilityFocusForUrgentStatus = movesAccessibilityFocusForUrgentStatus
  }

  var body: some View {
    Label(message, systemImage: severity.systemImage)
      .font(.callout)
      .foregroundStyle(severity.color)
      .accessibilityElement(children: .combine)
      .accessibilityFocused($isAccessibilityFocused)
      .onAppear(perform: announceIfNeeded)
      .onChange(of: message) { _, _ in
        announceIfNeeded()
      }
  }

  private func announceIfNeeded() {
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let policy = AccessibleStatusAnnouncementPolicy(
      severity: severity,
      announcesNonUrgentStatus: announcesNonUrgentStatus,
      movesAccessibilityFocusForUrgentStatus: movesAccessibilityFocusForUrgentStatus
    )
    guard policy.shouldAnnounce, let priority = policy.priority else { return }
    DispatchQueue.main.async {
      if policy.shouldMoveAccessibilityFocus {
        isAccessibilityFocused = true
      }
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: message,
          .priority: priority.appKitPriority.rawValue,
        ]
      )
    }
  }
}

struct QuickHideOverlay: View {
  @ObservedObject var store: WorkbenchStore
  @FocusState private var isUnlockButtonFocused: Bool
  @AccessibilityFocusState private var isOverlayFocused: Bool

  var body: some View {
    let status = store.privacyProtectionStatus

    VStack(spacing: 14) {
      Image(systemName: "eye.slash")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)

      Text(status.title)
        .font(.title2.weight(.semibold))

      Text(status.detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)

      if !status.activeProtections.isEmpty {
        HStack(spacing: 8) {
          ForEach(status.activeProtections, id: \.self) { protection in
            Label(protection, systemImage: "checkmark.shield")
              .font(.caption)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(WorkbenchBackgroundStyle.control, in: Capsule())
          }
        }
      }

      Button {
        store.deactivateQuickHide()
      } label: {
        Label("返回工作台", systemImage: "eye")
      }
      .keyboardShortcut(.return, modifiers: [])
      .focused($isUnlockButtonFocused)
      .accessibilityFocused($isOverlayFocused)
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("quick-hide-overlay")
    .accessibilityLabel(status.title)
    .accessibilityHint(status.detail)
    .background {
      QuickHideReturnKeyCapture {
        store.deactivateQuickHide()
      }
    }
    .onAppear {
      DispatchQueue.main.async {
        isUnlockButtonFocused = true
        isOverlayFocused = true
      }
    }
  }
}

enum QuickHideReturnKeyPolicy {
  private static let returnKeyCodes: Set<UInt16> = [36, 76]
  private static let blockingModifiers: NSEvent.ModifierFlags = [
    .command, .control, .option, .shift,
  ]

  static func matches(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    returnKeyCodes.contains(keyCode)
      && modifierFlags.intersection(blockingModifiers).isEmpty
  }
}

private struct QuickHideReturnKeyCapture: NSViewRepresentable {
  let onReturn: @MainActor () -> Void

  func makeNSView(context: Context) -> QuickHideReturnKeyCaptureView {
    let view = QuickHideReturnKeyCaptureView()
    view.onReturn = onReturn
    return view
  }

  func updateNSView(_ nsView: QuickHideReturnKeyCaptureView, context: Context) {
    nsView.onReturn = onReturn
  }

  static func dismantleNSView(
    _ nsView: QuickHideReturnKeyCaptureView,
    coordinator: Void
  ) {
    nsView.stopMonitoring()
  }
}

@MainActor
private final class QuickHideReturnKeyCaptureView: NSView {
  var onReturn: @MainActor () -> Void = {}
  private var eventMonitor: Any?

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      stopMonitoring()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self,
        self.window?.isKeyWindow == true,
        QuickHideReturnKeyPolicy.matches(
          keyCode: event.keyCode,
          modifierFlags: event.modifierFlags
        )
      else { return event }

      self.onReturn()
      return nil
    }
  }

  func stopMonitoring() {
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }
}

extension Date {
  var workbenchShortText: String {
    formatted(date: .abbreviated, time: .shortened)
  }
}

extension Array where Element == String {
  var commaSeparated: String {
    joined(separator: ", ")
  }
}

extension ImageCoverPublishState {
  var systemImage: String {
    switch self {
    case .ready:
      return "star.circle.fill"
    case .disabled:
      return "star.slash"
    case .privateSuppressed:
      return "lock.shield"
    case .missingCover:
      return "star"
    case .missingAttachment:
      return "xmark.octagon"
    case .missingPublishPath:
      return "exclamationmark.triangle"
    case .missingSource:
      return "photo.badge.exclamationmark"
    }
  }

  var color: Color {
    switch self {
    case .ready:
      return WorkbenchTheme.success
    case .disabled, .privateSuppressed:
      return .secondary
    case .missingCover, .missingPublishPath:
      return WorkbenchTheme.warning
    case .missingAttachment, .missingSource:
      return WorkbenchTheme.risk
    }
  }
}

struct GuidedEmptyStateAction: Identifiable {
  let id: String
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let systemImage: String
  let action: () -> Void
}

struct GuidedEmptyStateView: View {
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let systemImage: String
  let actions: [GuidedEmptyStateAction]
  @State private var hoveredActionID: String?

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 12) {
        ZStack {
          Circle()
            .fill(Color.accentColor.opacity(0.12))
            .frame(width: 72, height: 72)

          Image(systemName: systemImage)
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }

        VStack(spacing: 4) {
          Text(title)
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)

          Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
      }

      if !actions.isEmpty {
        VStack(spacing: 10) {
          ForEach(actions) { item in
            let isHovered = hoveredActionID == item.id

            Button {
              item.action()
            } label: {
              actionCard(for: item, isHovered: isHovered)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
              withAnimation(WorkbenchMotion.hoverSpring) {
                hoveredActionID = hovering ? item.id : nil
              }
            }
          }
        }
        .frame(maxWidth: 440)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func actionCard(for item: GuidedEmptyStateAction, isHovered: Bool) -> some View {
    HStack(spacing: 14) {
      Image(systemName: item.systemImage)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .scaleEffect(isHovered ? 1.12 : 1.0)
        .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Text(item.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.5))
        .offset(x: isHovered ? 3 : 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isHovered ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(isHovered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: Color.accentColor.opacity(isHovered ? 0.16 : 0), radius: 10, x: 0, y: 4)
    .scaleEffect(isHovered ? 1.02 : 1.0)
  }
}
