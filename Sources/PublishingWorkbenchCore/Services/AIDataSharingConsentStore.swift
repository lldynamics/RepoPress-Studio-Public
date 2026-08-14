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
  /// Application-level remote AI gate. This is independent from the
  /// destination-specific grant. Local loopback eligibility ignores it.
  public let isRemoteAIEnabled: Bool
  public let isGranted: Bool

  public var requiresConsent: Bool {
    destinationState == .remote
  }

  public init(
    providerName: String,
    destination: String,
    destinationState: AIDataSharingDestinationState,
    isRemoteAIEnabled: Bool = true,
    isGranted: Bool
  ) {
    self.providerName = providerName
    self.destination = destination
    self.destinationState = destinationState
    self.isRemoteAIEnabled = isRemoteAIEnabled
    self.isGranted = isGranted
  }
}

public final class AIDataSharingConsentStore {
  public static let defaultStorageKey = "AIDataSharingConsent.allowedDestinations.v1"
  public static let defaultRemoteAIEnabledStorageKey =
    "AIDataSharingConsent.remoteAIEnabled.v1"

  private let defaults: UserDefaults
  private let storageKey: String
  private let remoteAIEnabledStorageKey: String

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = AIDataSharingConsentStore.defaultStorageKey,
    remoteAIEnabledStorageKey: String? = nil
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.remoteAIEnabledStorageKey = remoteAIEnabledStorageKey
      ?? (storageKey == AIDataSharingConsentStore.defaultStorageKey
        ? AIDataSharingConsentStore.defaultRemoteAIEnabledStorageKey
        : storageKey + ".remoteAIEnabled")
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
      isRemoteAIEnabled: isRemoteAIEnabled,
      isGranted: destinationState == .local
        || (destinationState == .remote
          && isRemoteAIEnabled
          && grantedIdentifiers.contains(config.dataSharingConsentIdentifier))
    )
  }

  /// Returns the application-level remote gate. A missing key is resolved for
  /// compatibility with existing installations that already had an explicit
  /// destination grant; a fresh installation with no grants starts closed.
  public var isRemoteAIEnabled: Bool {
    if let value = defaults.object(forKey: remoteAIEnabledStorageKey) as? Bool {
      return value
    }
    return !grantedIdentifiers.isEmpty
  }

  /// Persists the application-level remote gate without touching any
  /// destination-specific grants. Loopback requests do not consult this gate.
  public func setRemoteAIEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: remoteAIEnabledStorageKey)
  }

  @discardableResult
  public func grant(for config: AIProviderConfig) -> Bool {
    guard !config.dataSharingDestination.isEmpty else { return false }
    guard !config.isLocalEndpoint else { return true }
    // The first explicit destination grant is also the first explicit remote
    // opt-in for older installs. An explicit false can only be changed from
    // the dedicated master switch, never by a destination grant.
    if defaults.object(forKey: remoteAIEnabledStorageKey) == nil {
      defaults.set(true, forKey: remoteAIEnabledStorageKey)
    }
    var identifiers = grantedIdentifiers
    identifiers.insert(config.dataSharingConsentIdentifier)
    defaults.set(identifiers.sorted(), forKey: storageKey)
    return true
  }

  public func revoke(for config: AIProviderConfig) {
    var identifiers = grantedIdentifiers
    // Preserve the derived enabled state when an existing installation with
    // legacy destination grants first mutates that grant set. Otherwise,
    // revoking its last destination would also appear to disable the separate
    // application-level switch.
    if defaults.object(forKey: remoteAIEnabledStorageKey) == nil,
      !identifiers.isEmpty {
      defaults.set(true, forKey: remoteAIEnabledStorageKey)
    }
    identifiers.remove(config.dataSharingConsentIdentifier)
    defaults.set(identifiers.sorted(), forKey: storageKey)
  }

  private var grantedIdentifiers: Set<String> {
    Set(defaults.stringArray(forKey: storageKey) ?? [])
  }
}
