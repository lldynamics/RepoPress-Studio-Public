import Foundation
import PublishingCoreSupport

/// A reusable AI endpoint configuration shared by one or more site profiles.
///
/// Secrets are intentionally not part of this value. API keys are resolved by
/// `AICredentialStore` from the user-selected storage mode, while the site keeps
/// only the selected connection profile ID.
public struct AIConnectionProfile: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var config: AIProviderConfig
  /// Older snapshots may resolve origin-bound credentials. A copied
  /// configuration deliberately starts with its own credential identity.
  public var allowsLegacyCredentialFallback: Bool?

  public var canUseLegacyCredentials: Bool { allowsLegacyCredentialFallback != false }

  public init(
    id: UUID = UUID(),
    name: String,
    config: AIProviderConfig,
    allowsLegacyCredentialFallback: Bool? = nil
  ) {
    self.id = id
    self.name =
      name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? config.normalizedDisplayName
    self.config = config
    self.allowsLegacyCredentialFallback = allowsLegacyCredentialFallback
  }

  public var summary: String {
    [
      config.normalizedDisplayName,
      config.normalizedModel,
      config.dataSharingDestination,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: " · ")
  }

  public static func template(
    named name: String,
    preset: AIProviderPreset
  ) -> Self {
    var config = AIProviderConfig(preset: preset)
    config.applyPresetDefaults()
    // New connections opt out of application tools until the user enables
    // Agent explicitly. Legacy snapshots with a missing field still resolve
    // to the historical enabled behaviour.
    config.advancedSettings = AIProviderAdvancedSettings(
      allowsApplicationTools: false
    )
    return Self(name: name, config: config)
  }

  public static var templates: [Self] {
    [
      template(named: CoreL10n.text("Codex 套餐"), preset: .codexAppServer),
      template(named: CoreL10n.text("本地 Ollama"), preset: .local),
      template(named: "DeepSeek", preset: .deepSeek),
      template(named: CoreL10n.text("自定义云端接口"), preset: .custom),
    ]
  }
}
