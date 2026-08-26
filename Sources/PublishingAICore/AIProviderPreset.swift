import Foundation
import PublishingCoreSupport

public enum AIProviderCategory: String, CaseIterable, Identifiable, Sendable {
  case chatGPTAccount
  case apiService

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .chatGPTAccount:
      return CoreL10n.text("ChatGPT 账户登录")
    case .apiService:
      return CoreL10n.text("标准 API 凭据")
    }
  }
}

public enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case codexAppServer
  case openAICompatible
  case deepSeek
  case anthropic
  case gemini
  case siliconFlow
  case moonshot
  case zhipu
  case openRouter
  case local
  case custom

  public static let deepSeekHighQualityModel = "deepseek-v4-pro"
  public static let codexDefaultModel = "codex-default"

  private static let legacyDeepSeekProRawValue = "deepSeekPro"

  public var id: String { rawValue }

  public var category: AIProviderCategory {
    switch self {
    case .codexAppServer:
      return .chatGPTAccount
    case .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow, .moonshot, .zhipu,
      .openRouter, .local, .custom:
      return .apiService
    }
  }

  public var usesOpenAICompatibleProtocol: Bool {
    self != .codexAppServer
  }

  public var displayName: String {
    switch self {
    case .codexAppServer:
      return CoreL10n.text("Codex 套餐")
    case .openAICompatible:
      return CoreL10n.text("OpenAI 兼容")
    case .deepSeek:
      return "DeepSeek"
    case .anthropic:
      return "Anthropic (Claude)"
    case .gemini:
      return "Google Gemini"
    case .siliconFlow:
      return "SiliconFlow (硅基流动)"
    case .moonshot:
      return "Moonshot (Kimi)"
    case .zhipu:
      return CoreL10n.text("智谱 GLM")
    case .openRouter:
      return "OpenRouter"
    case .local:
      return CoreL10n.text("本地模型")
    case .custom:
      return CoreL10n.text("自定义")
    }
  }

  public var defaultBaseURL: String {
    switch self {
    case .codexAppServer:
      // This loopback-looking value is an internal transport identity only.
      // Requests for this preset are routed through `codex app-server` stdio
      // and never posted to this URL.
      return "http://127.0.0.1/__repopress_codex_app_server__"
    case .openAICompatible:
      return "https://api.openai.com/v1"
    case .deepSeek:
      return "https://api.deepseek.com"
    case .anthropic:
      return "https://api.anthropic.com/v1"
    case .gemini:
      return "https://generativelanguage.googleapis.com/v1beta/openai"
    case .siliconFlow:
      return "https://api.siliconflow.cn/v1"
    case .moonshot:
      return "https://api.moonshot.cn/v1"
    case .zhipu:
      return "https://open.bigmodel.cn/api/paas/v4"
    case .openRouter:
      return "https://openrouter.ai/api/v1"
    case .local:
      return "http://127.0.0.1:11434/v1"
    case .custom:
      return ""
    }
  }

  public var defaultModel: String {
    switch self {
    case .codexAppServer:
      // The App Server omits the model override for this sentinel so Codex can
      // choose the account's current default model.
      return Self.codexDefaultModel
    case .openAICompatible:
      return "gpt-4.1-mini"
    case .deepSeek:
      return "deepseek-v4-flash"
    case .anthropic:
      return "claude-sonnet-4-6"
    case .gemini:
      return "gemini-2.0-flash"
    case .siliconFlow:
      return "deepseek-ai/DeepSeek-V3"
    case .moonshot:
      return "moonshot-v1-auto"
    case .zhipu:
      return "glm-4-flash"
    case .openRouter, .custom:
      return ""
    case .local:
      return "llama3.1"
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    if rawValue == Self.legacyDeepSeekProRawValue {
      self = .deepSeek
      return
    }
    guard let preset = Self(rawValue: rawValue) else {
      self = .custom
      return
    }
    self = preset
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
