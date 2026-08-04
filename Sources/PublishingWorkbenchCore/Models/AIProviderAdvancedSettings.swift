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

  public init(
    systemPrompt: String = "",
    temperature: Double? = nil,
    maximumOutputTokens: Int? = nil,
    reasoningPreference: AIProviderReasoningPreference = .automatic
  ) {
    self.systemPrompt = systemPrompt
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.reasoningPreference = reasoningPreference
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
