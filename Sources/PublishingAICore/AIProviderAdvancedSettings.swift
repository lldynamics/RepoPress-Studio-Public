import Foundation
import PublishingCoreSupport

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
  /// Optional App Server reasoning level selected for the authenticated
  /// ChatGPT/Codex account. A raw string keeps this forward compatible with
  /// levels added by the service after this build.
  public var reasoningEffortOverride: String?
  /// Optional for backwards-compatible connection profiles. A missing value
  /// keeps the historical behaviour (the native Agent path is enabled).
  public var allowsApplicationTools: Bool?
  /// Optional fine-grained Agent scopes. A missing value is deliberately
  /// resolved to `localRead + draftCreation` so legacy profiles do not gain
  /// network, content, repository, or publishing authority after upgrade.
  public var agentPermissionPolicy: AIAgentPermissionPolicy?
  /// Optional proxy URL for network requests (e.g. http://127.0.0.1:7890 or socks5://127.0.0.1:7890).
  public var proxyURL: String?
  /// Reserved persisted fallback profile. Runtime failover is intentionally
  /// not enabled until authorization, cycle detection, and replay rules exist.
  public var fallbackProfileID: UUID?

  public init(
    systemPrompt: String = "",
    temperature: Double? = nil,
    maximumOutputTokens: Int? = nil,
    reasoningPreference: AIProviderReasoningPreference = .automatic,
    reasoningEffortOverride: String? = nil,
    allowsApplicationTools: Bool? = nil,
    agentPermissionPolicy: AIAgentPermissionPolicy? = nil,
    proxyURL: String? = nil,
    fallbackProfileID: UUID? = nil
  ) {
    self.systemPrompt = systemPrompt
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.reasoningPreference = reasoningPreference
    self.reasoningEffortOverride = Self.normalizeReasoningEffort(reasoningEffortOverride)
    self.allowsApplicationTools = allowsApplicationTools
    self.agentPermissionPolicy = agentPermissionPolicy
    self.proxyURL = proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.fallbackProfileID = fallbackProfileID
  }

  /// Resolves the optional persisted value. Existing profiles that do not
  /// contain the field keep Agent behaviour enabled.
  public var resolvedAllowsApplicationTools: Bool {
    allowsApplicationTools ?? true
  }

  /// Returns the persisted policy or the migration-safe baseline for legacy
  /// snapshots that have no fine-grained scope field.
  public var resolvedAgentPermissionPolicy: AIAgentPermissionPolicy {
    agentPermissionPolicy ?? .legacySafeDefault
  }

  /// The scopes that can actually be consumed by an Agent after applying the
  /// connection-level master switch.
  public var effectiveAgentPermissionPolicy: AIAgentPermissionPolicy {
    AIAgentPermissionPolicy(
      enabledScopes: resolvedAgentPermissionPolicy.effectiveScopes(
        masterEnabled: resolvedAllowsApplicationTools
      )
    )
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

  public var normalizedReasoningEffortOverride: String? {
    Self.normalizeReasoningEffort(reasoningEffortOverride)
  }

  public var normalizedProxyURL: String? {
    proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  public var isDefault: Bool {
    normalizedSystemPrompt.isEmpty
      && normalizedTemperature == nil
      && normalizedMaximumOutputTokens == nil
      && reasoningPreference == .automatic
      && normalizedReasoningEffortOverride == nil
      && allowsApplicationTools == nil
      && (agentPermissionPolicy == nil || agentPermissionPolicy?.isDefault == true)
      && normalizedProxyURL == nil
      && fallbackProfileID == nil
  }

  private static func normalizeReasoningEffort(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case systemPrompt
    case temperature
    case maximumOutputTokens
    case reasoningPreference
    case reasoningEffortOverride
    case allowsApplicationTools
    case agentPermissionPolicy
    case proxyURL
    case fallbackProfileID
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
    reasoningEffortOverride = Self.normalizeReasoningEffort(
      try container.decodeIfPresent(String.self, forKey: .reasoningEffortOverride)
    )
    allowsApplicationTools = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsApplicationTools
    )
    agentPermissionPolicy = try container.decodeIfPresent(
      AIAgentPermissionPolicy.self,
      forKey: .agentPermissionPolicy
    )
    proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).nilIfEmpty
    fallbackProfileID = try container.decodeIfPresent(UUID.self, forKey: .fallbackProfileID)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encodeIfPresent(temperature, forKey: .temperature)
    try container.encodeIfPresent(maximumOutputTokens, forKey: .maximumOutputTokens)
    try container.encode(reasoningPreference, forKey: .reasoningPreference)
    try container.encodeIfPresent(
      normalizedReasoningEffortOverride,
      forKey: .reasoningEffortOverride
    )
    try container.encodeIfPresent(allowsApplicationTools, forKey: .allowsApplicationTools)
    try container.encodeIfPresent(agentPermissionPolicy, forKey: .agentPermissionPolicy)
    try container.encodeIfPresent(normalizedProxyURL, forKey: .proxyURL)
    try container.encodeIfPresent(fallbackProfileID, forKey: .fallbackProfileID)
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
