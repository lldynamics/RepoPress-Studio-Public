import Foundation

public enum AIDataSharingDestinationState: Equatable, Sendable {
  case unconfigured
  case local
  case remote
}

public struct AIDataSharingConsentPresentation: Equatable, Sendable {
  public let providerName: String
  public let destination: String
  public let destinationState: AIDataSharingDestinationState
  public let isGranted: Bool

  public var requiresConsent: Bool {
    destinationState == .remote
  }

  public init(
    providerName: String,
    destination: String,
    destinationState: AIDataSharingDestinationState,
    isGranted: Bool
  ) {
    self.providerName = providerName
    self.destination = destination
    self.destinationState = destinationState
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
    let destination = config.dataSharingDestination
    let destinationState: AIDataSharingDestinationState
    if destination.isEmpty {
      destinationState = .unconfigured
    } else if config.isLocalEndpoint {
      destinationState = .local
    } else {
      destinationState = .remote
    }
    return AIDataSharingConsentPresentation(
      providerName: config.normalizedDisplayName,
      destination: destination,
      destinationState: destinationState,
      isGranted: destinationState == .local
        || (destinationState == .remote
          && grantedIdentifiers.contains(config.dataSharingConsentIdentifier))
    )
  }

  @discardableResult
  public func grant(for config: AIProviderConfig) -> Bool {
    guard !config.dataSharingDestination.isEmpty else { return false }
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
