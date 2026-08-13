import Foundation

public struct AIConnectionTestReport: Equatable, Sendable {
  public var providerName: String
  public var model: String
  public var endpoint: URL
  public var responsePreview: String
  public var capabilityProbeReport: AIProviderCapabilityProbeReport?

  public init(
    providerName: String,
    model: String,
    endpoint: URL,
    responsePreview: String,
    capabilityProbeReport: AIProviderCapabilityProbeReport? = nil
  ) {
    self.providerName = providerName
    self.model = model
    self.endpoint = endpoint
    self.responsePreview = responsePreview
    self.capabilityProbeReport = capabilityProbeReport
  }

  public var headline: String {
    CoreL10n.format("%@ 连接正常", providerName)
  }

  public var detailText: String {
    CoreL10n.format("模型：%@\n接口地址：%@\n响应：%@", model, endpoint.absoluteString, responsePreview)
  }

  public var hasCapabilityEvidence: Bool {
    capabilityProbeReport?.results.isEmpty == false
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
    if config.normalizedBaseURL.isEmpty {
      return AISettingsConnectionPresentation(
        title: CoreL10n.text("AI 服务尚未配置"),
        message: CoreL10n.text("API Base URL 尚未配置。"),
        footnote: CoreL10n.text("请先填写 API Base URL 和模型，再保存凭据并测试连接。"),
        systemImage: "gearshape",
        level: .warning
      )
    }

    if let report {
      return AISettingsConnectionPresentation(
        title: report.headline,
        message: report.detailText,
        footnote: CoreL10n.text("连接测试已返回响应，当前服务、模型和接口地址可用于 AI 功能。"),
        systemImage: "checkmark.circle",
        level: .success
      )
    }

    if config.requiresAPIKey,
      let accessFailureMessage = tokenAvailability.accessFailureMessage
    {
      return AISettingsConnectionPresentation(
        title: CoreL10n.text("AI 凭据读取失败"),
        message: accessFailureMessage,
        footnote: providerHelpText(config),
        systemImage: "exclamationmark.triangle",
        level: .warning
      )
    }

    if config.requiresAPIKey && !tokenAvailability.hasToken {
      return AISettingsConnectionPresentation(
        title: CoreL10n.text("AI API Key 未就绪"),
        message: CoreL10n.text("请先保存当前站点的 AI API Key，再测试连接。"),
        footnote: providerHelpText(config),
        systemImage: "key",
        level: .warning
      )
    }

    return AISettingsConnectionPresentation(
      title: CoreL10n.text("AI 连接尚未测试"),
      message: CoreL10n.text("建议保存配置后测试一次连接，确认接口地址、模型和 API Key 都可用。"),
      footnote: providerHelpText(config),
      systemImage: "network",
      level: .info
    )
  }

  private static func providerHelpText(_ config: AIProviderConfig) -> String {
    switch config.preset {
    case .deepSeek:
      return CoreL10n.text(
        "DeepSeek 默认接口地址：https://api.deepseek.com；快速/标准档使用 deepseek-v4-flash，高质量档使用 deepseek-v4-pro。"
      )
    case .local:
      return CoreL10n.text("本地模型默认不需要 API Key，测试连接会请求本机开放AI兼容接口的 /chat/completions。")
    default:
      return CoreL10n.text("测试连接会向开放AI兼容接口的 /chat/completions 发送一次最小请求。")
    }
  }
}

public enum AIConnectionTestError: LocalizedError, Equatable {
  case missingBaseURL
  case invalidBaseURL(String)
  case missingModel
  case missingAPIKey

  public var errorDescription: String? {
    switch self {
    case .missingBaseURL:
      return CoreL10n.text("API Base URL 尚未配置。")
    case .invalidBaseURL(let value):
      return CoreL10n.format("AI 接口地址无效：%@", value)
    case .missingModel:
      return CoreL10n.text("请先填写 AI 模型名称。")
    case .missingAPIKey:
      return CoreL10n.text("请先保存 AI API Key，或关闭“需要 API Key”。")
    }
  }
}

public struct AIConnectionTestService: Sendable {
  private let client: AIChatCompletionClient
  private let capabilityProbeService: AIProviderCapabilityProbeService

  public init(
    client: AIChatCompletionClient = AIChatCompletionClient(),
    capabilityProbeService: AIProviderCapabilityProbeService? = nil
  ) {
    self.client = client
    self.capabilityProbeService =
      capabilityProbeService
      ?? AIProviderCapabilityProbeService(client: client)
  }

  public func testConnection(
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIConnectionTestReport {
    try await testConnection(
      config: config,
      apiKey: apiKey,
      probeCapabilities: [],
      forceRefresh: false
    )
  }

  public func testConnection(
    config: AIProviderConfig,
    apiKey: String?,
    probeCapabilities: Set<AIProviderCapabilityProbeKind>,
    forceRefresh: Bool = false
  ) async throws -> AIConnectionTestReport {
    guard !config.normalizedBaseURL.isEmpty else {
      throw AIConnectionTestError.missingBaseURL
    }

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
        temperature: 0,
        maximumOutputTokens: 8
      ),
      config: config,
      apiKey: normalizedAPIKey,
      purpose: .connectionTest
    )

    let capabilityProbeReport: AIProviderCapabilityProbeReport?
    if probeCapabilities.isEmpty {
      capabilityProbeReport = nil
    } else {
      capabilityProbeReport = try await capabilityProbeService.probe(
        config: config,
        apiKey: normalizedAPIKey,
        capabilities: probeCapabilities,
        forceRefresh: forceRefresh,
        existingChatProof: probeCapabilities.contains(.chat)
          ? AIProviderCapabilityChatProbeProof(
            key: AIProviderCapabilityCacheKey(config: config),
            result: result
          )
          : nil
      )
    }

    return AIConnectionTestReport(
      providerName: config.preset.displayName,
      model: result.rawModel?.nilIfEmpty ?? model,
      endpoint: endpoint,
      responsePreview: String(result.content.trimmedForPublishing.prefix(80)),
      capabilityProbeReport: capabilityProbeReport
    )
  }
}
