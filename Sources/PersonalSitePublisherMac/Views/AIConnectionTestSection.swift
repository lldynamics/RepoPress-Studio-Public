import PublishingWorkbenchCore
import SwiftUI

enum AIConnectionTestAvailability: Equatable {
  case ready
  case missingBaseURL
  case missingModel
  case missingAPIKey
  case credentialAccessFailed(String)
  case consentRequired

  init(
    config: AIProviderConfig,
    tokenAvailability: KeychainTokenAvailability,
    dataSharingConsent: AIDataSharingConsentPresentation
  ) {
    if config.normalizedBaseURL.isEmpty {
      self = .missingBaseURL
    } else if config.normalizedModel.isEmpty {
      self = .missingModel
    } else if config.requiresAPIKey,
      let accessFailureMessage = tokenAvailability.accessFailureMessage
    {
      self = .credentialAccessFailed(accessFailureMessage)
    } else if config.requiresAPIKey && !tokenAvailability.hasToken {
      self = .missingAPIKey
    } else if !dataSharingConsent.isGranted {
      self = .consentRequired
    } else {
      self = .ready
    }
  }

  var isEnabled: Bool {
    self == .ready
  }

  var message: String {
    switch self {
    case .ready:
      return String(localized: "准备就绪，可以发送一次最小请求验证当前服务。")
    case .missingBaseURL:
      return String(localized: "请先在“连接与服务”中填写 API 基础地址。")
    case .missingModel:
      return String(localized: "请先在“连接与服务”中选择或填写模型。")
    case .missingAPIKey:
      return String(localized: "请先在上方保存当前连接所需的 API Key。")
    case .credentialAccessFailed(let detail):
      return String(localized: "凭据读取失败：\(detail)")
    case .consentRequired:
      return String(localized: "请先在上方明确同意 AI 数据发送授权。")
    }
  }

  var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle"
    case .missingBaseURL, .missingModel:
      return "gearshape"
    case .missingAPIKey:
      return "key"
    case .credentialAccessFailed:
      return "exclamationmark.triangle"
    case .consentRequired:
      return "hand.raised"
    }
  }
}

struct AIConnectionTestSection: View {
  let config: AIProviderConfig
  let tokenAvailability: KeychainTokenAvailability
  let dataSharingConsent: AIDataSharingConsentPresentation
  let report: AIConnectionTestReport?
  let isReportStale: Bool
  let isAIActionRunning: Bool
  let isConnectionTestRunning: Bool
  let hasAttemptedConnectionTest: Bool
  let actionMessage: String?
  let onTestConnection: () -> Void

  var body: some View {
    Section("3. 连接测试") {
      connectionStatus

      Button {
        onTestConnection()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "network")
            .workbenchSyncSymbolEffect(trigger: isConnectionTestRunning ? 1 : 0)
          Text(
            isConnectionTestRunning
              ? String(localized: "正在测试…")
              : String(localized: "测试连接")
          )
        }
      }
      .workbenchProminentActionStyle()
      .disabled(!availability.isEnabled || isAIActionRunning || isConnectionTestRunning)
      .accessibilityLabel(
        isConnectionTestRunning
          ? String(localized: "正在测试 AI 连接")
          : String(localized: "测试 AI 连接")
      )
      .accessibilityHint(availability.message)

      if !availability.isEnabled {
        Label(availability.message, systemImage: availability.systemImage)
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.warning)
          .accessibilityElement(children: .combine)
      } else if !hasAttemptedConnectionTest && !isReportStale {
        Text(availability.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("测试会向当前服务发送一次最小请求，不会发送站点文章或资料库内容。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var availability: AIConnectionTestAvailability {
    AIConnectionTestAvailability(
      config: config,
      tokenAvailability: tokenAvailability,
      dataSharingConsent: dataSharingConsent
    )
  }

  @ViewBuilder
  private var connectionStatus: some View {
    if isConnectionTestRunning {
      AccessibleStatusMessage(
        message: String(localized: "正在测试 AI 连接…"),
        severity: .info,
        announcesNonUrgentStatus: true
      )
    } else if isReportStale {
      AccessibleStatusMessage(
        message: String(localized: "AI 配置、授权或 Key 已变化，之前的连接测试结果已失效。"),
        severity: .warning,
        movesAccessibilityFocusForUrgentStatus: false
      )
    } else if hasAttemptedConnectionTest, let report {
      AccessibleStatusMessage(
        message: report.headline,
        severity: .success,
        announcesNonUrgentStatus: true
      )
      Text(report.detailText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    } else if hasAttemptedConnectionTest {
      AccessibleStatusMessage(
        message: actionMessage
          ?? String(localized: "AI 连接测试失败，请检查地址、授权、凭据和网络后重试。"),
        severity: .error
      )
    } else {
      let presentation = AISettingsConnectionPresentationService.presentation(
        config: config,
        tokenAvailability: tokenAvailability,
        report: nil
      )
      Label(presentation.title, systemImage: presentation.systemImage)
        .font(.callout.weight(.semibold))
        .foregroundStyle(statusColor(presentation.level))
      Text(presentation.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  private func statusColor(_ level: AISettingsConnectionStatusLevel) -> Color {
    switch level {
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return .secondary
    }
  }
}
