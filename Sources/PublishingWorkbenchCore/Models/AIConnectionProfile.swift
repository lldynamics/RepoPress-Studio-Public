import Foundation

/// A reusable AI endpoint configuration shared by one or more site profiles.
///
/// Secrets are intentionally not part of this value. API keys are stored in
/// Keychain under the connection profile ID, while the site keeps only the
/// selected connection profile ID.
public struct AIConnectionProfile: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var config: AIProviderConfig

  public init(
    id: UUID = UUID(),
    name: String,
    config: AIProviderConfig
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? config.normalizedDisplayName
    self.config = config
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
    return Self(name: name, config: config)
  }

  public static var templates: [Self] {
    [
      template(named: CoreL10n.text("本地 Ollama"), preset: .local),
      template(named: "DeepSeek", preset: .deepSeek),
      template(named: CoreL10n.text("自定义云端接口"), preset: .custom),
    ]
  }
}
