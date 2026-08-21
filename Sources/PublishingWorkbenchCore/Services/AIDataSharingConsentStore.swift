import CryptoKit
import Foundation

/// A privacy-preserving identity used to bind the ChatGPT data-sharing grant
/// to the account that was explicitly approved by the user. The original
/// account identifier or email is intentionally never retained in this value
/// or in UserDefaults; only `digest` is persisted by the consent store.
public struct CodexAppServerAccountIdentity: Equatable, Sendable {
  public enum Source: String, Equatable, Sendable {
    case accountID
    case email
  }

  public let source: Source
  public let digest: String

  private init(source: Source, canonicalValue: String) {
    self.source = source
    let digest = SHA256.hash(data: Data(canonicalValue.utf8))
    self.digest = digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Resolves a stable identity from a live app-server account response.
  /// Account ID is preferred. Email is only a normalized fallback because it
  /// is the least-bad stable identifier exposed by older app-server builds.
  public static func resolve(from status: CodexAppServerAccountStatus)
    -> CodexAppServerAccountIdentity?
  {
    guard status.isAuthenticated else { return nil }

    if let accountID = normalizedAccountID(status.accountID) {
      return CodexAppServerAccountIdentity(
        source: .accountID,
        canonicalValue: "account-id:\(accountID)"
      )
    }
    guard let email = normalizedEmail(status.email) else { return nil }
    return CodexAppServerAccountIdentity(
      source: .email,
      canonicalValue: "email:\(email)"
    )
  }

  private static func normalizedAccountID(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty, normalized.count <= 512 else { return nil }
    guard
      normalized.unicodeScalars.allSatisfy({ scalar in
        !scalar.properties.isWhitespace && scalar.value >= 0x20 && scalar.value != 0x7F
      })
    else {
      return nil
    }
    return normalized
  }

  private static func normalizedEmail(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
      .lowercased()
    guard normalized.count <= 320 else { return nil }
    let components = normalized.split(separator: "@", omittingEmptySubsequences: false)
    guard components.count == 2,
      !components[0].isEmpty,
      !components[1].isEmpty,
      normalized.unicodeScalars.allSatisfy({ scalar in
        !scalar.properties.isWhitespace && scalar.value >= 0x20 && scalar.value != 0x7F
      })
    else {
      return nil
    }
    return normalized
  }
}

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
  /// Whether this exact remote destination has been granted before the
  /// application-level gate is applied. This stays true while the master
  /// switch is off so the UI can explain that the grant is retained.
  public let hasDestinationGrant: Bool
  /// A Codex grant exists, but it cannot be used until the currently logged-in
  /// account is explicitly re-authorized. This is deliberately separate from
  /// `hasDestinationGrant`, which describes the persisted destination grant.
  public let requiresAccountReauthorization: Bool
  public let isGranted: Bool

  public var requiresConsent: Bool {
    destinationState == .remote
  }

  public init(
    providerName: String,
    destination: String,
    destinationState: AIDataSharingDestinationState,
    isRemoteAIEnabled: Bool = true,
    isGranted: Bool,
    hasDestinationGrant: Bool? = nil,
    requiresAccountReauthorization: Bool = false
  ) {
    self.providerName = providerName
    self.destination = destination
    self.destinationState = destinationState
    self.isRemoteAIEnabled = isRemoteAIEnabled
    self.hasDestinationGrant =
      hasDestinationGrant
      ?? (destinationState == .remote ? isGranted : false)
    self.requiresAccountReauthorization = requiresAccountReauthorization
    self.isGranted = isGranted
  }
}

public final class AIDataSharingConsentStore: @unchecked Sendable {
  public static let defaultStorageKey = "AIDataSharingConsent.allowedDestinations.v1"
  public static let defaultRemoteAIEnabledStorageKey =
    "AIDataSharingConsent.remoteAIEnabled.v1"
  public static let defaultCodexAccountBindingStorageKey =
    "AIDataSharingConsent.codexAccountBindingDigest.v1"

  private let defaults: UserDefaults
  private let storageKey: String
  private let remoteAIEnabledStorageKey: String
  private let codexAccountBindingStorageKey: String

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = AIDataSharingConsentStore.defaultStorageKey,
    remoteAIEnabledStorageKey: String? = nil,
    codexAccountBindingStorageKey: String? = nil
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.remoteAIEnabledStorageKey =
      remoteAIEnabledStorageKey
      ?? (storageKey == AIDataSharingConsentStore.defaultStorageKey
        ? AIDataSharingConsentStore.defaultRemoteAIEnabledStorageKey
        : storageKey + ".remoteAIEnabled")
    self.codexAccountBindingStorageKey =
      codexAccountBindingStorageKey
      ?? (storageKey == AIDataSharingConsentStore.defaultStorageKey
        ? AIDataSharingConsentStore.defaultCodexAccountBindingStorageKey
        : storageKey + ".codexAccountBindingDigest")
  }

  public func presentation(
    for config: AIProviderConfig
  ) -> AIDataSharingConsentPresentation {
    // Synchronous callers (notably the API-key helper) only need the
    // destination/master-switch gate. The final Codex send path performs the
    // live account check through `CodexAppServerRequestAuthorizer`.
    presentation(
      for: config,
      codexAccountStatus: nil,
      requiresLiveCodexAccount: false
    )
  }

  /// Presents consent using a live account response when the provider is
  /// Codex. Without a live status, Codex remains fail-closed even when an
  /// account-bound grant exists in storage.
  public func presentation(
    for config: AIProviderConfig,
    codexAccountStatus: CodexAppServerAccountStatus?
  ) -> AIDataSharingConsentPresentation {
    presentation(
      for: config,
      codexAccountStatus: codexAccountStatus,
      requiresLiveCodexAccount: true
    )
  }

  private func presentation(
    for config: AIProviderConfig,
    codexAccountStatus: CodexAppServerAccountStatus?,
    requiresLiveCodexAccount: Bool
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
    let hasDestinationGrant =
      destinationState == .remote
      && grantedIdentifiers.contains(config.dataSharingConsentIdentifier)
    let codexBindingValid: Bool
    if config.usesCodexAppServer {
      codexBindingValid =
        hasDestinationGrant
        && codexAccountBindingDigest != nil
        && (!requiresLiveCodexAccount
          || codexAccountStatus.flatMap(CodexAppServerAccountIdentity.resolve)?.digest
            == codexAccountBindingDigest)
    } else {
      codexBindingValid = true
    }
    let requiresAccountReauthorization =
      config.usesCodexAppServer
      && (hasDestinationGrant || codexAccountBindingDigest != nil)
      && !codexBindingValid
    let isGranted =
      destinationState == .local
      || (destinationState == .remote
        && isRemoteAIEnabled
        && hasDestinationGrant
        && codexBindingValid)
    return AIDataSharingConsentPresentation(
      providerName: config.normalizedDisplayName,
      destination: destination,
      destinationState: destinationState,
      isRemoteAIEnabled: isRemoteAIEnabled,
      isGranted: isGranted,
      hasDestinationGrant: hasDestinationGrant,
      requiresAccountReauthorization: requiresAccountReauthorization
    )
  }

  /// The digest currently stored for the Codex account binding. It is exposed
  /// only for diagnostics/tests and never reconstructs the original identity.
  public var codexAccountBindingDigest: String? {
    defaults.string(forKey: codexAccountBindingStorageKey)
  }

  /// Returns whether a live, authenticated account is the one explicitly
  /// bound to the current Codex destination grant and the remote gate is on.
  public func isCodexAccountAuthorized(
    for config: AIProviderConfig,
    accountStatus: CodexAppServerAccountStatus
  ) -> Bool {
    guard config.usesCodexAppServer else { return true }
    return presentation(for: config, codexAccountStatus: accountStatus).isGranted
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
    grant(for: config, codexAccountStatus: nil)
  }

  /// Grants a destination. Codex requires a live authenticated account with a
  /// stable identity; the legacy unbound destination grant is never silently
  /// upgraded by this overload.
  @discardableResult
  public func grant(
    for config: AIProviderConfig,
    codexAccountStatus: CodexAppServerAccountStatus?
  ) -> Bool {
    guard !config.dataSharingDestination.isEmpty else { return false }
    guard !config.isLocalEndpoint else { return true }
    if config.usesCodexAppServer {
      guard let accountStatus = codexAccountStatus,
        let identity = CodexAppServerAccountIdentity.resolve(from: accountStatus)
      else {
        return false
      }
      defaults.set(identity.digest, forKey: codexAccountBindingStorageKey)
    }
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
      !identifiers.isEmpty
    {
      defaults.set(true, forKey: remoteAIEnabledStorageKey)
    }
    identifiers.remove(config.dataSharingConsentIdentifier)
    defaults.set(identifiers.sorted(), forKey: storageKey)
    if config.usesCodexAppServer {
      defaults.removeObject(forKey: codexAccountBindingStorageKey)
    }
  }

  private var grantedIdentifiers: Set<String> {
    Set(defaults.stringArray(forKey: storageKey) ?? [])
  }
}
