import Foundation

public struct AIDataSharingConsentPresentation: Equatable, Sendable {
  public let providerName: String
  public let destination: String
  public let requiresConsent: Bool
  public let isGranted: Bool

  public init(
    providerName: String,
    destination: String,
    requiresConsent: Bool,
    isGranted: Bool
  ) {
    self.providerName = providerName
    self.destination = destination
    self.requiresConsent = requiresConsent
    self.isGranted = isGranted
  }
}

public final class AIDataSharingConsentStore {
  private let defaults: UserDefaults
  private let storageKey: String

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = "AIDataSharingConsent.allowedDestinations.v1"
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
  }

  public func presentation(
    for config: AIProviderConfig
  ) -> AIDataSharingConsentPresentation {
    let requiresConsent = !config.isLocalEndpoint
    return AIDataSharingConsentPresentation(
      providerName: config.normalizedDisplayName,
      destination: config.dataSharingDestination,
      requiresConsent: requiresConsent,
      isGranted: !requiresConsent || grantedIdentifiers.contains(config.dataSharingConsentIdentifier)
    )
  }

  @discardableResult
  public func grant(for config: AIProviderConfig) -> Bool {
    guard !config.isLocalEndpoint else { return true }
    var identifiers = grantedIdentifiers
    identifiers.insert(config.dataSharingConsentIdentifier)
    defaults.set(identifiers.sorted(), forKey: storageKey)
    return true
  }

  public func revoke(for config: AIProviderConfig) {
    var identifiers = grantedIdentifiers
    identifiers.remove(config.dataSharingConsentIdentifier)
    defaults.set(identifiers.sorted(), forKey: storageKey)
  }

  private var grantedIdentifiers: Set<String> {
    Set(defaults.stringArray(forKey: storageKey) ?? [])
  }
}
