import Foundation

/// Official onboarding destinations for a bundled cloud provider.
///
/// These links are intentionally withheld when a preset points at a different
/// gateway. The provider label alone is not proof that the gateway owns the
/// account or accepts the provider's credentials.
public struct AIProviderSetupGuide: Equatable, Sendable {
  public let provider: AIProviderPreset
  public let apiKeyURL: URL?
  public let accountURL: URL
  public let modelsURL: URL

  public init(
    provider: AIProviderPreset,
    apiKeyURL: URL?,
    accountURL: URL,
    modelsURL: URL
  ) {
    self.provider = provider
    self.apiKeyURL = apiKeyURL
    self.accountURL = accountURL
    self.modelsURL = modelsURL
  }

  /// Returns a guide only for a bundled provider endpoint. Custom and changed
  /// gateway configurations deliberately return `nil`.
  public static func guide(for config: AIProviderConfig) -> AIProviderSetupGuide? {
    guard let links = links(for: config.preset),
      config.capabilityEndpointIdentity == bundledEndpointIdentity(for: config.preset)
    else {
      return nil
    }
    return AIProviderSetupGuide(
      provider: config.preset,
      apiKeyURL: links.apiKeyURL,
      accountURL: links.accountURL,
      modelsURL: links.modelsURL
    )
  }

  private struct Links {
    let apiKeyURL: URL?
    let accountURL: URL
    let modelsURL: URL
  }

  private static func bundledEndpointIdentity(for preset: AIProviderPreset) -> String {
    AIProviderConfig(
      preset: preset,
      baseURL: preset.defaultBaseURL,
      model: preset.defaultModel
    ).capabilityEndpointIdentity
  }

  private static func links(for preset: AIProviderPreset) -> Links? {
    switch preset {
    case .openAICompatible:
      return Links(
        apiKeyURL: URL(string: "https://platform.openai.com/api-keys"),
        accountURL: URL(string: "https://platform.openai.com/account")!,
        modelsURL: URL(string: "https://platform.openai.com/docs/models")!
      )
    case .deepSeek:
      return Links(
        apiKeyURL: URL(string: "https://platform.deepseek.com/api_keys"),
        accountURL: URL(string: "https://platform.deepseek.com/")!,
        modelsURL: URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!
      )
    case .anthropic:
      return Links(
        apiKeyURL: URL(string: "https://console.anthropic.com/settings/keys"),
        accountURL: URL(string: "https://console.anthropic.com/")!,
        modelsURL: URL(string: "https://docs.anthropic.com/en/docs/about-claude/models")!
      )
    case .gemini:
      return Links(
        apiKeyURL: URL(string: "https://aistudio.google.com/app/apikey"),
        accountURL: URL(string: "https://aistudio.google.com/")!,
        modelsURL: URL(string: "https://ai.google.dev/gemini-api/docs/models")!
      )
    case .siliconFlow:
      return Links(
        apiKeyURL: URL(string: "https://cloud.siliconflow.cn/account/ak"),
        accountURL: URL(string: "https://cloud.siliconflow.cn/")!,
        modelsURL: URL(string: "https://docs.siliconflow.cn/en/userguide/models")!
      )
    case .moonshot:
      return Links(
        apiKeyURL: URL(string: "https://platform.moonshot.cn/console/api-keys"),
        accountURL: URL(string: "https://platform.moonshot.cn/")!,
        modelsURL: URL(string: "https://platform.moonshot.cn/docs/intro")!
      )
    case .zhipu:
      return Links(
        apiKeyURL: URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"),
        accountURL: URL(string: "https://open.bigmodel.cn/")!,
        modelsURL: URL(string: "https://docs.bigmodel.cn/cn/guide/start/model-overview")!
      )
    case .openRouter:
      return Links(
        apiKeyURL: URL(string: "https://openrouter.ai/settings/keys"),
        accountURL: URL(string: "https://openrouter.ai/")!,
        modelsURL: URL(string: "https://openrouter.ai/docs/models")!
      )
    case .codexAppServer, .local, .custom:
      return nil
    }
  }
}
