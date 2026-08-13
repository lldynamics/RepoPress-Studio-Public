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
  @Binding var selectedProbeCapabilities: Set<AIProviderCapabilityProbeKind>
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

      capabilityProbeSelection
    }
  }

  private var capabilityProbeSelection: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("可选能力探测")
        .font(.caption.weight(.semibold))
      Text("默认不额外探测。勾选后会增加对应请求；选择普通对话会复用本次最小 ping。")
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      ForEach(AIProviderCapabilityProbeKind.allCases) { capability in
        Toggle(
          localizedProbeCapabilityName(capability),
          isOn: probeBinding(for: capability)
        )
        .toggleStyle(.checkbox)
        .disabled(!availability.isEnabled || isAIActionRunning || isConnectionTestRunning)
        .accessibilityIdentifier("settings-ai-capability-probe-\(capability.rawValue)")
      }
    }
    .padding(.top, 4)
    .accessibilityElement(children: .contain)
  }

  private func probeBinding(
    for capability: AIProviderCapabilityProbeKind
  ) -> Binding<Bool> {
    Binding(
      get: { selectedProbeCapabilities.contains(capability) },
      set: { isSelected in
        if isSelected {
          selectedProbeCapabilities.insert(capability)
        } else {
          selectedProbeCapabilities.remove(capability)
        }
      }
    )
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
      if let capabilityProbeReport = report.capabilityProbeReport {
        VStack(alignment: .leading, spacing: 4) {
          Text("能力探测结果")
            .font(.caption.weight(.semibold))
          ForEach(
            capabilityProbeReport.results.values.sorted {
              $0.capability.rawValue < $1.capability.rawValue
            },
            id: \.capability
          ) { result in
            let observationLabel =
              result.fromCache
              ? CoreL10n.text("缓存")
              : CoreL10n.text("本次探测")
            Text(
              "\(localizedProbeCapabilityName(result.capability))：\(localizedProbeOutcomeName(result.outcome))"
                + " · \(observationLabel)"
            )
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
          }
          Text("状态：\(localizedProbeCacheStateName(capabilityProbeReport.cacheState))")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
      }
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

  private func localizedProbeCapabilityName(
    _ capability: AIProviderCapabilityProbeKind
  ) -> String {
    switch capability {
    case .chat:
      return CoreL10n.text("普通对话")
    case .streamingResponse:
      return CoreL10n.text("流式响应")
    case .toolCalling:
      return CoreL10n.text("工具调用")
    case .structuredOutput:
      return CoreL10n.text("结构化输出")
    case .visionInput:
      return CoreL10n.text("视觉输入")
    }
  }

  private func localizedProbeOutcomeName(
    _ outcome: AIProviderCapabilityProbeOutcome
  ) -> String {
    switch outcome {
    case .supported:
      return CoreL10n.text("支持")
    case .unsupported:
      return CoreL10n.text("不支持")
    case .inconclusive:
      return CoreL10n.text("未知（结果不确定）")
    }
  }

  private func localizedProbeCacheStateName(
    _ state: AIProviderCapabilityProbeCacheState
  ) -> String {
    switch state {
    case .hit:
      return CoreL10n.text("缓存命中")
    case .partialHit:
      return CoreL10n.text("部分缓存命中")
    case .miss:
      return CoreL10n.text("首次探测")
    case .expired:
      return CoreL10n.text("已过期，重新探测")
    case .forcedRefresh:
      return CoreL10n.text("强制刷新")
    }
  }
}
