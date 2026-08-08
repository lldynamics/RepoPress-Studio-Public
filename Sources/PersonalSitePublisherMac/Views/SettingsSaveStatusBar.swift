import PublishingWorkbenchCore
import SwiftUI

enum SettingsSaveStatusKind: Equatable {
  case idle
  case saving
  case warning
  case error
}

struct SettingsSaveStatusPresentation: Equatable {
  let kind: SettingsSaveStatusKind
  let title: String
  let canRetry: Bool

  init(
    hasUnsavedChanges: Bool,
    lastSaveError: String?,
    isRecoveryWriteProtected: Bool,
    recoveryMessage: String?
  ) {
    if isRecoveryWriteProtected {
      kind = .error
      title =
        recoveryMessage?.nilIfEmpty
        ?? String(localized: "当前工作台处于恢复保护状态，普通设置不会覆盖原始数据。")
      canRetry = false
    } else if let lastSaveError = lastSaveError?.nilIfEmpty {
      if hasUnsavedChanges {
        kind = .error
        title = String(localized: "保存失败：\(lastSaveError)")
        canRetry = true
      } else {
        kind = .warning
        title = String(localized: "设置已保存，但备份副本失败：\(lastSaveError)")
        canRetry = false
      }
    } else if hasUnsavedChanges {
      kind = .saving
      title = String(localized: "正在保存…")
      canRetry = false
    } else {
      kind = .idle
      title = String(localized: "设置会自动保存")
      canRetry = false
    }
  }

  var systemImage: String {
    switch kind {
    case .idle:
      return "arrow.triangle.2.circlepath"
    case .saving:
      return "arrow.triangle.2.circlepath"
    case .warning, .error:
      return "exclamationmark.triangle"
    }
  }
}

struct SettingsSaveStatusBar: View {
  let hasUnsavedChanges: Bool
  let lastSaveError: String?
  let isRecoveryWriteProtected: Bool
  let recoveryMessage: String?
  let retry: () -> Void

  private var presentation: SettingsSaveStatusPresentation {
    SettingsSaveStatusPresentation(
      hasUnsavedChanges: hasUnsavedChanges,
      lastSaveError: lastSaveError,
      isRecoveryWriteProtected: isRecoveryWriteProtected,
      recoveryMessage: recoveryMessage
    )
  }

  var body: some View {
    HStack(spacing: WorkbenchSpacing.control) {
      if presentation.kind == .error || presentation.kind == .warning {
        AccessibleStatusMessage(
          message: presentation.title,
          severity: presentation.kind == .error ? .error : .warning,
          movesAccessibilityFocusForUrgentStatus: presentation.kind == .error
        )
        .font(.workbenchMetadata)
        .lineLimit(2)
      } else if presentation.kind == .saving {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
        Text(presentation.title)
          .font(.workbenchMetadata)
          .foregroundStyle(statusColor)
          .lineLimit(2)
      } else {
        Image(systemName: presentation.systemImage)
          .foregroundStyle(statusColor)
          .accessibilityHidden(true)
        Text(presentation.title)
          .font(.workbenchMetadata)
          .foregroundStyle(statusColor)
          .lineLimit(2)
      }

      Spacer(minLength: WorkbenchSpacing.control)

      Text("普通设置自动保存；API Key 与访问令牌需点击保存。")
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)

      if presentation.canRetry {
        Button("重试") {
          retry()
        }
        .buttonStyle(.borderless)
        .accessibilityHint("重新保存当前工作台设置")
      }
    }
    .padding(.horizontal, WorkbenchSpacing.content)
    .padding(.vertical, 7)
    .background(WorkbenchBackgroundStyle.subtle)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-save-status")
  }

  private var statusColor: Color {
    switch presentation.kind {
    case .error:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .idle, .saving:
      return .secondary
    }
  }
}
