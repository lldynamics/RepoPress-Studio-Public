import Foundation
import PublishingAICore
import PublishingCoreSupport

enum AIConnectionSetupNextStep: Equatable {
  case missingBaseURL
  case invalidEndpoint
  case missingAPIKey
  case credentialAccessFailed
  case missingModel
  case consentRequired
  case changedGateway
  case testing
  case success
  case ready
}

struct AIConnectionSetupPresentation: Equatable {
  let nextStep: AIConnectionSetupNextStep
  let title: String
  let message: String
  let guide: AIProviderSetupGuide?

  static func make(
    config: AIProviderConfig,
    tokenAvailability: KeychainTokenAvailability,
    dataSharingConsent: AIDataSharingConsentPresentation,
    report: AIConnectionTestReport?,
    isTesting: Bool
  ) -> AIConnectionSetupPresentation {
    let guide = AIProviderSetupGuide.guide(for: config)
    if isTesting {
      return AIConnectionSetupPresentation(
        nextStep: .testing,
        title: String(localized: "正在验证连接"),
        message: String(localized: "正在向当前服务发送一次最小请求。"),
        guide: guide
      )
    }

    if dataSharingConsent.requiresAccountReauthorization {
      return make(
        .consentRequired,
        String(localized: "需要重新授权 AI 数据发送"),
        String(localized: "当前 ChatGPT 账户授权已失效，请重新明确同意后再测试连接。"),
        guide
      )
    }

    let availability = AIConnectionTestAvailability(
      config: config,
      tokenAvailability: tokenAvailability,
      dataSharingConsent: dataSharingConsent
    )
    if availability == .ready, let report,
      report.requestedModel == config.normalizedModel,
      report.endpoint == config.chatCompletionsURL
    {
      return AIConnectionSetupPresentation(
        nextStep: .success,
        title: report.headline,
        message: String(localized: "当前服务与模型已通过连接验证。可以开始使用 AI 功能。"),
        guide: guide
      )
    }
    switch availability {
    case .missingBaseURL:
      return make(
        .missingBaseURL, String(localized: "尚未填写服务地址"), String(localized: "请先填写 API 基础地址。"), guide)
    case .invalidEndpoint:
      return make(.invalidEndpoint, String(localized: "服务地址无效"), availability.message, guide)
    case .missingModel:
      return make(.missingModel, String(localized: "尚未选择模型"), availability.message, guide)
    case .credentialAccessFailed:
      return make(.credentialAccessFailed, String(localized: "凭据读取失败"), availability.message, guide)
    case .missingAPIKey:
      return make(.missingAPIKey, String(localized: "API Key 未就绪"), availability.message, guide)
    case .consentRequired:
      return make(.consentRequired, String(localized: "需要 AI 数据发送授权"), availability.message, guide)
    case .ready:
      if guide == nil, config.preset != .local, config.preset != .custom {
        return make(
          .changedGateway,
          String(localized: "已使用自定义网关"),
          String(localized: "当前预设的服务地址已修改；请向该网关的运营方获取凭据和模型信息，再测试连接。"),
          nil
        )
      }
      return make(.ready, String(localized: "可以验证连接"), availability.message, guide)
    }
  }

  private static func make(
    _ nextStep: AIConnectionSetupNextStep,
    _ title: String,
    _ message: String,
    _ guide: AIProviderSetupGuide?
  ) -> AIConnectionSetupPresentation {
    AIConnectionSetupPresentation(nextStep: nextStep, title: title, message: message, guide: guide)
  }
}
