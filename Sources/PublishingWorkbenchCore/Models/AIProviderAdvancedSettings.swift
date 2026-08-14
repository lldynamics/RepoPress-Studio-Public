import Foundation

/// Optional chat-only overrides for one reusable AI connection profile.
///
/// Structured publishing actions keep their own conservative request options;
/// these values apply only to interactive assistant conversations.
public struct AIProviderAdvancedSettings: Codable, Hashable, Sendable {
  public static let maximumSystemPromptLength = 8_000
  public static let maximumOutputTokenLimit = 131_072

  public var systemPrompt: String
  public var temperature: Double?
  public var maximumOutputTokens: Int?
  public var reasoningPreference: AIProviderReasoningPreference
  /// Optional for backwards-compatible connection profiles. A missing value
  /// keeps the historical behaviour (the native Agent path is enabled).
  public var allowsApplicationTools: Bool?

  public init(
    systemPrompt: String = "",
    temperature: Double? = nil,
    maximumOutputTokens: Int? = nil,
    reasoningPreference: AIProviderReasoningPreference = .automatic,
    allowsApplicationTools: Bool? = nil
  ) {
    self.systemPrompt = systemPrompt
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.reasoningPreference = reasoningPreference
    self.allowsApplicationTools = allowsApplicationTools
  }

  /// Resolves the optional persisted value. Existing profiles that do not
  /// contain the field keep Agent behaviour enabled.
  public var resolvedAllowsApplicationTools: Bool {
    allowsApplicationTools ?? true
  }

  public var normalizedSystemPrompt: String {
    String(
      systemPrompt
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(Self.maximumSystemPromptLength)
    )
  }

  public var normalizedTemperature: Double? {
    temperature.map { min(2, max(0, $0)) }
  }

  public var normalizedMaximumOutputTokens: Int? {
    maximumOutputTokens.map { min(Self.maximumOutputTokenLimit, max(1, $0)) }
  }

  public var isDefault: Bool {
    normalizedSystemPrompt.isEmpty
      && normalizedTemperature == nil
      && normalizedMaximumOutputTokens == nil
      && reasoningPreference == .automatic
      && allowsApplicationTools == nil
  }

  private enum CodingKeys: String, CodingKey {
    case systemPrompt
    case temperature
    case maximumOutputTokens
    case reasoningPreference
    case allowsApplicationTools
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
    maximumOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens)
    reasoningPreference =
      try container.decodeIfPresent(
        AIProviderReasoningPreference.self,
        forKey: .reasoningPreference
      ) ?? .automatic
    allowsApplicationTools = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsApplicationTools
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encodeIfPresent(temperature, forKey: .temperature)
    try container.encodeIfPresent(maximumOutputTokens, forKey: .maximumOutputTokens)
    try container.encode(reasoningPreference, forKey: .reasoningPreference)
    try container.encodeIfPresent(allowsApplicationTools, forKey: .allowsApplicationTools)
  }
}

public enum AIProviderReasoningPreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case disabled
  case low
  case medium
  case high

  public var id: String { rawValue }

  public var localizedTitle: String {
    switch self {
    case .automatic:
      return CoreL10n.text("自动")
    case .disabled:
      return CoreL10n.text("关闭")
    case .low:
      return CoreL10n.text("低")
    case .medium:
      return CoreL10n.text("中")
    case .high:
      return CoreL10n.text("高")
    }
  }
}
