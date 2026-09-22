import PublishingAICore
import SwiftUI

struct AIConnectionSetupSection: View {
  let config: AIProviderConfig
  let presentation: AIConnectionSetupPresentation
  let isAIActionRunning: Bool
  let onContinue: () -> Void

  var body: some View {
    Section(String(localized: "连接准备")) {
      Label(
        title,
        systemImage: presentation.nextStep == .success
          ? "checkmark.circle.fill" : "arrow.right.circle"
      )
      .font(.headline)
      Text(message).font(.callout).foregroundStyle(.secondary)
      HStack {
        Button(actionTitle, action: onContinue)
          .workbenchProminentActionStyle()
          .disabled(isContinueDisabled)
          .accessibilityIdentifier("settings-ai-setup-continue")
        if let guide = presentation.guide {
          if let url = guide.apiKeyURL { Link(String(localized: "获取 API Key"), destination: url) }
          Link(String(localized: "账户与用量"), destination: guide.accountURL)
          Link(String(localized: "模型说明"), destination: guide.modelsURL)
        }
      }
    }
    .accessibilityIdentifier("settings-ai-setup-summary")
  }

  private var title: String {
    if config.usesCodexAppServer { return String(localized: "准备 ChatGPT 账户连接") }
    if config.preset == .local { return String(localized: "准备这台 Mac 上的 AI") }
    return presentation.title
  }

  private var isContinueDisabled: Bool {
    if presentation.nextStep == .testing { return true }
    guard isAIActionRunning, !config.usesCodexAppServer, config.preset != .local else {
      return false
    }
    return [.ready, .changedGateway, .success].contains(presentation.nextStep)
  }

  private var message: String {
    if config.usesCodexAppServer { return String(localized: "检查连接组件、登录账户，再选择账户可用模型。") }
    if config.preset == .local { return String(localized: "检测本地服务，按需启动本地引擎或准备模型，然后应用到当前连接。") }
    return presentation.message
  }

  private var actionTitle: String {
    if config.usesCodexAppServer { return String(localized: "检查与登录") }
    if config.preset == .local { return String(localized: "准备本地模型") }
    switch presentation.nextStep {
    case .missingBaseURL, .invalidEndpoint: return String(localized: "填写服务地址")
    case .missingAPIKey: return String(localized: "填写 API Key")
    case .credentialAccessFailed: return String(localized: "检查凭据")
    case .missingModel: return String(localized: "获取并选择模型")
    case .consentRequired: return String(localized: "查看数据发送授权")
    case .testing: return String(localized: "正在验证…")
    case .success: return String(localized: "重新验证")
    case .changedGateway, .ready: return String(localized: "验证并完成")
    }
  }
}
