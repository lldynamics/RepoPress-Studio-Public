import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

struct CodexRuntimeSetupSection: View {
  @ObservedObject var connection: CodexConnectionController
  @State private var showDetails = false
  @State private var showAdvanced = false

  var body: some View {
    if needsSetupPresentation {
      VStack(alignment: .leading, spacing: 8) {
        Label(setupTitle, systemImage: "shippingbox")
          .font(.headline)
        Text(runtimeManagementTitle)
          .font(.caption.weight(.medium))
        Text(setupDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          if showsPrepareAction {
            Button(primaryActionTitle) { connection.prepare() }
              .workbenchProminentActionStyle()
              .disabled(connection.isChecking || connection.isPreparing)
              .accessibilityIdentifier("settings-ai-codex-prepare")
          }
          Button(String(localized: "重新检测")) {
            Task { await connection.refresh() }
          }
          .buttonStyle(.borderless)
          .disabled(connection.isChecking || connection.isPreparing)
          if connection.isPreparing {
            ProgressView().controlSize(.small)
          }
          if connection.canCancelPreparation {
            Button(String(localized: "取消")) { connection.cancelPreparation() }
              .buttonStyle(.borderless)
          }
        }
        if let progress = connection.progress?.nilIfEmpty {
          Text(progress).font(.caption).accessibilityIdentifier(
            "settings-ai-codex-prepare-progress")
        }
        if let failure = connection.failure?.nilIfEmpty {
          Text(failure).font(.caption).foregroundStyle(WorkbenchTheme.warning).textSelection(
            .enabled)
        }
        if connection.canRollback {
          Button(String(localized: "回退到上一个已验证版本")) { connection.rollback() }
            .buttonStyle(.borderless)
            .disabled(connection.isPreparing || connection.isChecking)
        }
        if connection.runtimeStatus?.source == .managed,
          connection.runtimeStatus?.isAvailable == true
        {
          Toggle(String(localized: "自动更新已验证的 Codex 组件"), isOn: $connection.automaticallyUpdates)
            .font(.caption)
            .disabled(connection.isPreparing || connection.isChecking)
        }
        if isManagedRuntime {
          DisclosureGroup(String(localized: "高级选项"), isExpanded: $showAdvanced) {
            Button(String(localized: "改用系统 CLI（会切换连接组件）")) {
              connection.useSystemRuntime()
            }
            .buttonStyle(.borderless)
            .disabled(connection.isPreparing || connection.isChecking)
            Text(String(localized: "此操作会停止使用本应用管理的组件，并重新检测系统安装的 Codex CLI。"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        DisclosureGroup(String(localized: "安装信息"), isExpanded: $showDetails) {
          Text(String(localized: "推荐版本：\(CodexRuntimeSetupService.recommendedVersion.description)"))
          if let path = connection.runtimeStatus?.executableURL?.path {
            Text(path).textSelection(.enabled)
          }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
  }

  private var needsSetupPresentation: Bool {
    connection.runtimeStatus != nil || connection.isChecking || connection.isPreparing
      || connection.failure != nil
  }

  private var showsPrepareAction: Bool {
    if isSystemRuntime { return true }
    if connection.failure != nil { return true }
    if hasRecommendedUpdate { return true }
    switch connection.phase {
    case .missingComponent, .updateRequired, .failed: return true
    case .needsLogin, .ready: return isManagedRuntime
    case .checking: return false
    }
  }

  private var setupTitle: String {
    if isSystemRuntime, connection.runtimeStatus?.isCompatible == true {
      return String(localized: "当前使用系统 Codex CLI")
    }
    if hasRecommendedUpdate {
      return String(localized: "连接组件有可用更新")
    }
    switch connection.phase {
    case .missingComponent: return String(localized: "首次使用需要准备连接组件")
    case .updateRequired: return String(localized: "连接组件有可用更新")
    case .failed: return String(localized: "需要修复 Codex 连接组件")
    case .checking: return String(localized: "正在检查 Codex 连接组件")
    case .needsLogin, .ready: return String(localized: "Codex 连接组件")
    }
  }

  private var setupDetail: String {
    if isSystemRuntime, connection.runtimeStatus?.isCompatible == true {
      return String(localized: "系统 CLI 当前可继续使用；如需由本应用下载并管理已验证版本，可在此切换。")
    }
    if hasRecommendedUpdate {
      return String(localized: "当前组件仍可使用；更新到本应用已验证版本是可选操作。")
    }
    switch connection.phase {
    case .missingComponent, .updateRequired, .failed:
      return String(localized: "本应用会安装或修复已验证的组件版本；完成后会重新检查账户。")
    case .checking:
      return String(localized: "正在读取组件和账户状态。")
    case .needsLogin, .ready:
      return String(localized: "组件状态由本应用统一管理。")
    }
  }

  private var primaryActionTitle: String {
    if isSystemRuntime, connection.runtimeStatus?.isCompatible == true {
      return String(localized: "改由本应用管理")
    }
    if hasRecommendedUpdate {
      return String(localized: "更新（当前版本仍可使用）")
    }
    switch connection.phase {
    case .updateRequired: return String(localized: "更新并继续")
    case .failed: return String(localized: "修复组件")
    case .needsLogin, .ready: return String(localized: "修复组件")
    default: return String(localized: "安装并继续")
    }
  }

  private var isSystemRuntime: Bool {
    connection.runtimeStatus?.source == .homebrew || connection.runtimeStatus?.source == .path
  }

  private var isManagedRuntime: Bool {
    connection.runtimeStatus?.source == .managed
  }

  private var hasRecommendedUpdate: Bool {
    guard let status = connection.runtimeStatus, status.isCompatible else { return false }
    return CodexRuntimeSetupService.needsRecommendedUpdate(status)
  }

  private var runtimeManagementTitle: String {
    guard connection.runtimeStatus?.isAvailable == true else {
      return String(localized: "默认由本应用管理")
    }
    return isManagedRuntime
      ? String(localized: "由本应用管理")
      : String(localized: "当前使用系统 CLI")
  }
}
