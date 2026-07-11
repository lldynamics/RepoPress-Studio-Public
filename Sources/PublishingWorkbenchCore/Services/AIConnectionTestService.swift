import Foundation

public struct AIConnectionTestReport: Equatable, Sendable {
  public var providerName: String
  public var model: String
  public var endpoint: URL
  public var responsePreview: String

  public init(
    providerName: String,
    model: String,
    endpoint: URL,
    responsePreview: String
  ) {
    self.providerName = providerName
    self.model = model
    self.endpoint = endpoint
    self.responsePreview = responsePreview
  }

  public var headline: String {
    "\(providerName) 连接正常"
  }

  public var detailText: String {
    """
    模型：\(model)
    Endpoint：\(endpoint.absoluteString)
    响应：\(responsePreview)
    """
  }
}

public enum AISettingsConnectionStatusLevel: Equatable, Sendable {
  case success
  case warning
  case info
}

public struct AISettingsConnectionPresentation: Equatable, Sendable {
  public var title: String
  public var message: String
  public var footnote: String
  public var systemImage: String
  public var level: AISettingsConnectionStatusLevel

  public init(
    title: String,
    message: String,
    footnote: String,
    systemImage: String,
    level: AISettingsConnectionStatusLevel
  ) {
    self.title = title
    self.message = message
    self.footnote = footnote
    self.systemImage = systemImage
    self.level = level
  }
}

public enum AISettingsConnectionPresentationService {
  public static func presentation(
    config: AIProviderConfig,
    tokenAvailability: KeychainTokenAvailability,
    report: AIConnectionTestReport?
  ) -> AISettingsConnectionPresentation {
    if let report {
      return AISettingsConnectionPresentation(
        title: report.headline,
        message: report.detailText,
        footnote: "连接测试已返回响应，当前 Provider、模型和 Endpoint 可用于 AI 功能。",
        systemImage: "checkmark.circle",
        level: .success
      )
    }

    if config.requiresAPIKey && !tokenAvailability.hasToken {
      return AISettingsConnectionPresentation(
        title: "AI API Key 未就绪",
        message: "请先保存当前 Profile 的 AI API Key，再测试连接。",
        footnote: providerHelpText(config),
        systemImage: "key",
        level: .warning
      )
    }

    return AISettingsConnectionPresentation(
      title: "AI 连接尚未测试",
      message: "建议保存配置后测试一次连接，确认 base_url、模型和 API Key 都可用。",
      footnote: providerHelpText(config),
      systemImage: "network",
      level: .info
    )
  }

  private static func providerHelpText(_ config: AIProviderConfig) -> String {
    switch config.preset {
    case .deepSeek:
      return "DeepSeek 默认 base_url：https://api.deepseek.com，模型 deepseek-v4-flash；聊天请求会发送 thinking 与 reasoning_effort。"
    case .deepSeekPro:
      return "DeepSeek Pro 使用 https://api.deepseek.com，模型 deepseek-v4-pro；聊天请求会发送 thinking 与 reasoning_effort。"
    case .local:
      return "本地模型默认不需要 API Key，测试连接会请求本机 OpenAI-compatible /chat/completions 接口。"
    default:
      return "测试连接会向 OpenAI-compatible /chat/completions 接口发送一次最小请求。"
    }
  }
}

public enum AIConnectionTestError: LocalizedError, Equatable {
  case invalidBaseURL(String)
  case missingModel
  case missingAPIKey

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return "AI Base URL 无效：\(value)"
    case .missingModel:
      return "请先填写 AI 模型名称。"
    case .missingAPIKey:
      return "请先保存 AI API Key，或关闭“需要 API Key”。"
    }
  }
}

public struct AIConnectionTestService: Sendable {
  private let client: AIChatCompletionClient

  public init(client: AIChatCompletionClient = AIChatCompletionClient()) {
    self.client = client
  }

  public func testConnection(
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIConnectionTestReport {
    let model = config.normalizedModel
    guard !model.isEmpty else {
      throw AIConnectionTestError.missingModel
    }

    let normalizedAPIKey = apiKey?.nilIfEmpty
    if config.requiresAPIKey && normalizedAPIKey == nil {
      throw AIConnectionTestError.missingAPIKey
    }

    guard let endpoint = config.chatCompletionsURL else {
      throw AIConnectionTestError.invalidBaseURL(config.normalizedBaseURL)
    }

    let result = try await client.complete(
      request: AIChatCompletionRequest(
        model: model,
        messages: [
          AIChatMessage(role: "system", content: "Return only OK."),
          AIChatMessage(role: "user", content: "ping"),
        ],
        temperature: 0
      ),
      config: config,
      apiKey: normalizedAPIKey,
      purpose: .connectionTest
    )

    return AIConnectionTestReport(
      providerName: config.preset.displayName,
      model: result.rawModel?.nilIfEmpty ?? model,
      endpoint: endpoint,
      responsePreview: String(result.content.trimmedForPublishing.prefix(80))
    )
  }
}
