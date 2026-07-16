import PublishingWorkbenchCore
import SwiftUI

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
        .font(.caption)
        .foregroundStyle(tint ?? .secondary)
      Text(value)
        .font(.title3.weight(.semibold))
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
      return WorkbenchTheme.primary
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

struct EmptyStateView: View {
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let systemImage: String
  let actionTitle: LocalizedStringKey?
  let actionSystemImage: String
  let action: (() -> Void)?

  init(
    title: LocalizedStringKey,
    message: LocalizedStringKey,
    systemImage: String,
    actionTitle: LocalizedStringKey? = nil,
    actionSystemImage: String = "arrow.right.circle",
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.actionTitle = actionTitle
    self.actionSystemImage = actionSystemImage
    self.action = action
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 38))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      if let actionTitle, let action {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct PrivacyLockOverlay: View {
  @ObservedObject var store: WorkbenchStore
  @FocusState private var isUnlockButtonFocused: Bool
  @AccessibilityFocusState private var isOverlayFocused: Bool

  var body: some View {
    let status = store.privacyProtectionStatus

    VStack(spacing: 14) {
      Image(systemName: "lock.shield")
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
              .background(WorkbenchBackgroundStyle.badge, in: Capsule())
          }
        }
      }

      Button {
        store.unlockPrivacy()
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
    .accessibilityIdentifier("privacy-lock-overlay")
    .accessibilityLabel(status.title)
    .accessibilityHint(status.detail)
    .onAppear {
      DispatchQueue.main.async {
        isUnlockButtonFocused = true
        isOverlayFocused = true
      }
    }
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
