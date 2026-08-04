import Foundation
import LocalAuthentication
import os
import Security

private let keychainTokenLogger = Logger(
  subsystem: "com.jinfang.PersonalSitePublisherMac",
  category: "KeychainTokenStore"
)

private final class KeychainTokenMutationCoordinator: @unchecked Sendable {
  static let shared = KeychainTokenMutationCoordinator()

  private let lock = NSRecursiveLock()

  private init() {}

  func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }
}

private final class InMemoryTokenBackend: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String: String] = [:]

  func token(for account: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return tokens[account]
  }

  func containsToken(for account: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return tokens[account] != nil
  }

  func saveToken(_ token: String, for account: String) {
    lock.lock()
    defer { lock.unlock() }
    tokens[account] = token
  }

  func deleteToken(for account: String) {
    lock.lock()
    defer { lock.unlock() }
    tokens.removeValue(forKey: account)
  }
}

public enum KeychainTokenAccessState: String, Codable, Hashable, Sendable {
  case available
  case missing
  case accessFailed
}

public struct KeychainTokenAvailability: Codable, Hashable, Sendable {
  public var hasToken: Bool
  public var updatedAt: Date?
  public var accessFailureMessage: String?

  private enum CodingKeys: String, CodingKey {
    case hasToken
    case updatedAt
    case accessFailureMessage
  }

  public init(
    hasToken: Bool,
    updatedAt: Date? = nil,
    accessFailureMessage: String? = nil
  ) {
    let normalizedAccessFailure = accessFailureMessage?
      .trimmedForPublishing
      .nilIfEmpty
    self.hasToken = normalizedAccessFailure == nil && hasToken
    self.updatedAt = updatedAt
    self.accessFailureMessage = normalizedAccessFailure
  }

  public init(accessFailure error: Error) {
    self.init(
      hasToken: false,
      accessFailureMessage: error.localizedDescription
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      hasToken: try container.decodeIfPresent(Bool.self, forKey: .hasToken) ?? false,
      updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
      accessFailureMessage: try container.decodeIfPresent(
        String.self,
        forKey: .accessFailureMessage
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hasToken, forKey: .hasToken)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(
      accessFailureMessage,
      forKey: .accessFailureMessage
    )
  }

  public var accessState: KeychainTokenAccessState {
    if accessFailureMessage != nil {
      return .accessFailed
    }
    return hasToken ? .available : .missing
  }
}

public struct KeychainTokenCleanupIssue: Hashable, Sendable {
  public var credential: String
  public var message: String

  public init(credential: String, message: String) {
    self.credential = credential
    self.message = message
  }
}

public struct KeychainTokenMutationReport: Hashable, Sendable {
  public var cleanupIssues: [KeychainTokenCleanupIssue]

  public init(cleanupIssues: [KeychainTokenCleanupIssue] = []) {
    self.cleanupIssues = cleanupIssues
  }

  public var hasWarnings: Bool {
    !cleanupIssues.isEmpty
  }
}

public enum KeychainTokenScope: Hashable, Sendable {
  case repository(RepositoryProvider)
  case deployment(DeploymentProvider)
  case analytics(SiteAnalyticsProvider)

  var accountComponent: String {
    switch self {
    case .repository(let provider):
      return "repository-\(provider.rawValue)"
    case .deployment(let provider):
      return "deployment-\(provider.rawValue)"
    case .analytics(let provider):
      return "analytics-\(provider.rawValue)"
    }
  }
}

public enum KeychainCredentialServices {
  #if DEBUG
  public static let ai = "PersonalSitePublisherMac.LocalDevelopment.AIProvider"
  public static let repository = "PersonalSitePublisherMac.LocalDevelopment.RepositoryProvider"
  public static let deployment = "PersonalSitePublisherMac.LocalDevelopment.DeploymentProvider"
  public static let analytics = "PersonalSitePublisherMac.LocalDevelopment.SiteAnalytics"
  public static let browserBridge = "PersonalSitePublisherMac.LocalDevelopment.BrowserBridge"
  #else
  public static let ai = "PersonalSitePublisherMac.AIProvider"
  public static let repository = "PersonalSitePublisherMac.RepositoryProvider"
  public static let deployment = "PersonalSitePublisherMac.DeploymentProvider"
  public static let analytics = "PersonalSitePublisherMac.SiteAnalytics"
  public static let browserBridge = "PersonalSitePublisherMac.BrowserBridge"
  #endif
}

public final class KeychainTokenStore: @unchecked Sendable {
  private let service: String
  private let accountPrefix: String
  private let allowsAuthenticationInteraction: Bool
  private let inMemoryBackend: InMemoryTokenBackend?
  private let deletionStatusOverrideForTesting: (@Sendable (String) -> OSStatus?)?

  public convenience init(
    service: String = KeychainCredentialServices.ai,
    accountPrefix: String = "ai-provider"
  ) {
    self.init(service: service, accountPrefix: accountPrefix, inMemory: false)
  }

  public convenience init(
    service: String,
    accountPrefix: String,
    inMemory: Bool = false,
    allowsAuthenticationInteraction: Bool = true
  ) {
    self.init(
      service: service,
      accountPrefix: accountPrefix,
      inMemory: inMemory,
      allowsAuthenticationInteraction: allowsAuthenticationInteraction,
      deletionStatusOverrideForTesting: nil
    )
  }

  init(
    service: String,
    accountPrefix: String,
    inMemory: Bool,
    allowsAuthenticationInteraction: Bool = true,
    deletionStatusOverrideForTesting: (@Sendable (String) -> OSStatus?)?
  ) {
    self.service = service
    self.accountPrefix = accountPrefix
    self.allowsAuthenticationInteraction = allowsAuthenticationInteraction
    self.inMemoryBackend = inMemory ? InMemoryTokenBackend() : nil
    self.deletionStatusOverrideForTesting = deletionStatusOverrideForTesting
  }

  public func token(for profile: SiteProfile) throws -> String? {
    try token(forAccount: account(for: profile))
  }

  public func token(for profile: SiteProfile, scope: KeychainTokenScope) throws -> String? {
    try token(forAccount: account(for: profile, scope: scope))
  }

  public func token(
    for profile: SiteProfile,
    scope: KeychainTokenScope,
    originURLText: String
  ) throws -> String? {
    try token(forAccount: credentialBoundAccount(
      for: profile,
      component: scope.accountComponent,
      originURLText: originURLText
    ))
  }

  public func aiToken(for profile: SiteProfile) throws -> String? {
    if let connectionID = profile.aiConnectionProfileID,
       let sharedToken = try aiToken(forConnectionProfileID: connectionID),
       !sharedToken.isEmpty {
      return sharedToken
    }
    return try token(forAccount: aiCredentialAccount(for: profile))
  }

  /// Reads the API key shared by every site that selects this connection.
  public func aiToken(forConnectionProfileID id: UUID) throws -> String? {
    try token(forAccountIdentifier: aiConnectionProfileAccountIdentifier(id))
  }

  public func repositoryToken(for profile: SiteProfile) throws -> String? {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    return try token(
      for: profile,
      scope: scope,
      originURLText: repositoryOriginURLText(for: profile)
    )
  }

  public func token(forAccountIdentifier identifier: String) throws -> String? {
    try token(forAccount: account(forAccountIdentifier: identifier))
  }

  public func availability(forAccountIdentifier identifier: String) throws -> KeychainTokenAvailability {
    try availability(forAccount: account(forAccountIdentifier: identifier))
  }

  public func saveToken(_ token: String, forAccountIdentifier identifier: String) throws {
    try saveToken(token, forAccount: account(forAccountIdentifier: identifier))
  }

  public func deleteToken(forAccountIdentifier identifier: String) throws {
    try deleteToken(forAccount: account(forAccountIdentifier: identifier))
  }

  public func availability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    try availability(forAccount: account(for: profile))
  }

  public func availability(for profile: SiteProfile, scope: KeychainTokenScope) throws -> KeychainTokenAvailability {
    try availability(forAccount: account(for: profile, scope: scope))
  }

  public func availability(
    for profile: SiteProfile,
    scope: KeychainTokenScope,
    originURLText: String
  ) throws -> KeychainTokenAvailability {
    try availability(forAccount: credentialBoundAccount(
      for: profile,
      component: scope.accountComponent,
      originURLText: originURLText
    ))
  }

  public func aiTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    if let connectionID = profile.aiConnectionProfileID {
      let sharedAvailability = try aiTokenAvailability(forConnectionProfileID: connectionID)
      if sharedAvailability.hasToken || sharedAvailability.accessFailureMessage != nil {
        return sharedAvailability
      }
    }
    return try availability(forAccount: aiCredentialAccount(for: profile))
  }

  public func aiTokenAvailability(forConnectionProfileID id: UUID) throws -> KeychainTokenAvailability {
    try availability(forAccount: account(forAccountIdentifier: aiConnectionProfileAccountIdentifier(id)))
  }

  public func repositoryTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    return try availability(
      for: profile,
      scope: scope,
      originURLText: repositoryOriginURLText(for: profile)
    )
  }

  @discardableResult
  public func saveRepositoryToken(
    _ token: String,
    for profile: SiteProfile
  ) throws -> KeychainTokenMutationReport {
    return try KeychainTokenMutationCoordinator.shared.synchronized {
      try saveToken(
        token,
        for: profile,
        scope: .repository(profile.repositoryProvider),
        originURLText: repositoryOriginURLText(for: profile)
      )
      // The origin-bound credential above is the only item read by current
      // releases. Cleanup of credentials created by older local builds is
      // deliberately best effort: an ad-hoc rebuild can retain an item whose
      // old ACL refuses deletion, and that must not turn a successful save
      // into a false failure.
      let cleanupIssues = [
        legacyCleanupIssue("legacy scoped repository credential") {
          try deleteToken(for: profile, scope: .repository(profile.repositoryProvider))
        },
        legacyCleanupIssue("legacy unscoped repository credential") {
          try deleteToken(for: profile)
        }
      ].compactMap { $0 }
      return KeychainTokenMutationReport(cleanupIssues: cleanupIssues)
    }
  }

  @discardableResult
  public func deleteRepositoryToken(
    for profile: SiteProfile
  ) throws -> KeychainTokenMutationReport {
    return try KeychainTokenMutationCoordinator.shared.synchronized {
      try deleteToken(
        for: profile,
        scope: .repository(profile.repositoryProvider),
        originURLText: repositoryOriginURLText(for: profile)
      )
      var cleanupIssues: [KeychainTokenCleanupIssue] = []
      if let issue = legacyCleanupIssue(
        "legacy scoped repository credential",
        operation: {
          try deleteToken(for: profile, scope: .repository(profile.repositoryProvider))
        }
      ) {
        cleanupIssues.append(issue)
      }
      // Older releases left this unscoped credential behind after migration.
      // It is no longer read by current releases, so a stale ACL must not make
      // deletion of the authoritative credential look unsuccessful.
      if let issue = legacyCleanupIssue(
        "legacy unscoped repository credential",
        operation: {
          try deleteToken(for: profile)
        }
      ) {
        cleanupIssues.append(issue)
      }
      return KeychainTokenMutationReport(cleanupIssues: cleanupIssues)
    }
  }

  public func saveToken(_ token: String, for profile: SiteProfile) throws {
    try saveToken(token, forAccount: account(for: profile))
  }

  public func saveToken(_ token: String, for profile: SiteProfile, scope: KeychainTokenScope) throws {
    try saveToken(token, forAccount: account(for: profile, scope: scope))
  }

  public func saveToken(
    _ token: String,
    for profile: SiteProfile,
    scope: KeychainTokenScope,
    originURLText: String
  ) throws {
    try saveToken(
      token,
      forAccount: credentialBoundAccount(
        for: profile,
        component: scope.accountComponent,
        originURLText: originURLText
      )
    )
  }

  @discardableResult
  public func saveAIToken(
    _ token: String,
    for profile: SiteProfile
  ) throws -> KeychainTokenMutationReport {
    if let connectionID = profile.aiConnectionProfileID {
      return try saveAIToken(token, forConnectionProfileID: connectionID)
    }
    return try KeychainTokenMutationCoordinator.shared.synchronized {
      try saveToken(token, forAccount: aiCredentialAccount(for: profile))
      // See saveRepositoryToken(_:for:). The scoped item is authoritative;
      // stale unscoped cleanup must not invalidate the completed save.
      let cleanupIssues = [
        legacyCleanupIssue("legacy unscoped AI credential") {
          try deleteToken(for: profile)
        }
      ].compactMap { $0 }
      return KeychainTokenMutationReport(cleanupIssues: cleanupIssues)
    }
  }

  /// Removes the origin-bound AI credential created before reusable
  /// connection profiles were introduced. The shared profile credential is
  /// managed by `saveAIToken(_:forConnectionProfileID:)` instead.
  @discardableResult
  public func deleteLegacyAIToken(
    for profile: SiteProfile
  ) throws -> KeychainTokenMutationReport {
    return try KeychainTokenMutationCoordinator.shared.synchronized {
      try deleteToken(forAccount: aiCredentialAccount(for: profile))
      return KeychainTokenMutationReport()
    }
  }

  @discardableResult
  public func saveAIToken(
    _ token: String,
    forConnectionProfileID id: UUID
  ) throws -> KeychainTokenMutationReport {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      try saveToken(
        token,
        forAccountIdentifier: aiConnectionProfileAccountIdentifier(id)
      )
      return KeychainTokenMutationReport()
    }
  }

  public func deleteToken(for profile: SiteProfile) throws {
    try deleteToken(forAccount: account(for: profile))
  }

  public func deleteToken(for profile: SiteProfile, scope: KeychainTokenScope) throws {
    try deleteToken(forAccount: account(for: profile, scope: scope))
  }

  public func deleteToken(
    for profile: SiteProfile,
    scope: KeychainTokenScope,
    originURLText: String
  ) throws {
    try deleteToken(forAccount: credentialBoundAccount(
      for: profile,
      component: scope.accountComponent,
      originURLText: originURLText
    ))
  }

  @discardableResult
  public func deleteAIToken(
    for profile: SiteProfile
  ) throws -> KeychainTokenMutationReport {
    if let connectionID = profile.aiConnectionProfileID {
      return try deleteAIToken(forConnectionProfileID: connectionID)
    }
    return try KeychainTokenMutationCoordinator.shared.synchronized {
      try deleteToken(forAccount: aiCredentialAccount(for: profile))
      let cleanupIssues = [
        legacyCleanupIssue("legacy unscoped AI credential") {
          try deleteToken(for: profile)
        }
      ].compactMap { $0 }
      return KeychainTokenMutationReport(cleanupIssues: cleanupIssues)
    }
  }

  @discardableResult
  public func deleteAIToken(
    forConnectionProfileID id: UUID
  ) throws -> KeychainTokenMutationReport {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      try deleteToken(forAccountIdentifier: aiConnectionProfileAccountIdentifier(id))
      return KeychainTokenMutationReport()
    }
  }

  private func legacyCleanupIssue(
    _ credential: String,
    operation: () throws -> Void
  ) -> KeychainTokenCleanupIssue? {
    do {
      try operation()
      return nil
    } catch {
      keychainTokenLogger.error(
        "Keychain cleanup failed for \(credential, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return KeychainTokenCleanupIssue(
        credential: credential,
        message: error.localizedDescription
      )
    }
  }

  @discardableResult
  public func migrateLegacyToken(
    for profile: SiteProfile,
    to scope: KeychainTokenScope,
    deleteLegacyToken: Bool = true
  ) throws -> Bool {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      if try token(for: profile, scope: scope) != nil {
        if deleteLegacyToken, try token(for: profile) != nil {
          try deleteToken(for: profile)
        }
        return false
      }
      guard let legacyToken = try token(for: profile) else {
        return false
      }
      try saveToken(legacyToken, for: profile, scope: scope)
      if deleteLegacyToken {
        try deleteToken(for: profile)
      }
      return true
    }
  }

  private func token(forAccount account: String) throws -> String? {
    if let inMemoryBackend {
      return inMemoryBackend.token(for: account)
    }

    var query = readQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainTokenStoreError.unhandledStatus(status)
    }
    guard let data = result as? Data else {
      throw KeychainTokenStoreError.invalidData
    }
    return String(data: data, encoding: .utf8)
  }

  private func availability(forAccount account: String) throws -> KeychainTokenAvailability {
    if let inMemoryBackend {
      return KeychainTokenAvailability(hasToken: inMemoryBackend.containsToken(for: account))
    }

    var query = readQuery(account: account)
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return KeychainTokenAvailability(hasToken: false)
    }
    guard status == errSecSuccess else {
      throw KeychainTokenStoreError.unhandledStatus(status)
    }

    guard let attributes = result as? [String: Any],
          let data = attributes[kSecValueData as String] as? Data else {
      throw KeychainTokenStoreError.invalidData
    }
    return KeychainTokenAvailability(
      hasToken: !data.isEmpty,
      updatedAt: attributes[kSecAttrModificationDate as String] as? Date
    )
  }

  private func saveToken(_ token: String, forAccount account: String) throws {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      if let inMemoryBackend {
        inMemoryBackend.saveToken(token, for: account)
        return
      }

      let data = Data(token.utf8)
      var query = baseQuery(account: account)
      let attributes = [kSecValueData as String: data] as CFDictionary

      let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
      if updateStatus == errSecSuccess {
        return
      }
      guard updateStatus == errSecItemNotFound else {
        throw KeychainTokenStoreError.unhandledStatus(updateStatus)
      }

      query[kSecValueData as String] = data
      #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      #endif
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      if addStatus == errSecSuccess {
        return
      }
      if addStatus == errSecDuplicateItem {
        let retryStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes)
        guard retryStatus == errSecSuccess else {
          throw KeychainTokenStoreError.unhandledStatus(retryStatus)
        }
        return
      }
      throw KeychainTokenStoreError.unhandledStatus(addStatus)
    }
  }

  private func deleteToken(forAccount account: String) throws {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      if let status = deletionStatusOverrideForTesting?(account) {
        throw KeychainTokenStoreError.unhandledStatus(status)
      }
      if let inMemoryBackend {
        inMemoryBackend.deleteToken(for: account)
        return
      }

      let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
      if status == errSecSuccess || status == errSecItemNotFound {
        return
      }
      if Self.isRecoverableDeletionOwnershipStatus(status) {
        // Legacy macOS keychain ACLs can allow a newer signed build to read and
        // update an item but reject deletion as an owner edit. Clearing the
        // value removes the credential; availability treats empty data as no
        // token, so the user-facing result remains a real deletion.
        let updateStatus = SecItemUpdate(
          baseQuery(account: account) as CFDictionary,
          [kSecValueData as String: Data()] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
          throw KeychainTokenStoreError.unhandledStatus(updateStatus)
        }
        return
      }
      throw KeychainTokenStoreError.unhandledStatus(status)
    }
  }

  static func isRecoverableDeletionOwnershipStatus(_ status: OSStatus) -> Bool {
    status == errSecInvalidOwnerEdit || status == -25253
  }

  private func account(for profile: SiteProfile) -> String {
    "\(accountPrefix)-\(profile.id.uuidString)"
  }

  private func account(forAccountIdentifier identifier: String) -> String {
    "\(accountPrefix)-named-\(identifier)"
  }

  private func account(for profile: SiteProfile, scope: KeychainTokenScope) -> String {
    "\(account(for: profile))-\(scope.accountComponent)"
  }

  private func aiCredentialAccount(for profile: SiteProfile) throws -> String {
    try credentialBoundAccount(
      for: profile,
      component: "ai-\(profile.aiProviderConfig.preset.rawValue)",
      originURLText: profile.aiProviderConfig.normalizedBaseURL
    )
  }

  private func aiConnectionProfileAccountIdentifier(_ id: UUID) -> String {
    "ai-connection-profile-" + id.uuidString
  }

  private func repositoryOriginURLText(for profile: SiteProfile) -> String {
    profile.repositoryBaseURL.nilIfEmpty ?? profile.repositoryProvider.defaultBaseURL
  }

  private func credentialBoundAccount(
    for profile: SiteProfile,
    component: String,
    originURLText: String
  ) throws -> String {
    guard let origin = normalizedCredentialOrigin(originURLText) else {
      throw KeychainTokenStoreError.invalidCredentialOrigin(originURLText)
    }
    let originComponent = Data(origin.utf8).base64EncodedString()
    return "\(account(for: profile))-\(component)-origin-\(originComponent)"
  }

  private func normalizedCredentialOrigin(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          scheme == "https",
          let host = components.host?.lowercased(),
          !host.isEmpty,
          components.user == nil,
          components.password == nil else {
      return nil
    }
    return "\(scheme)://\(host):\(components.port ?? 443)"
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private func readQuery(account: String) -> [String: Any] {
    var query = baseQuery(account: account)
    if !allowsAuthenticationInteraction {
      let context = LAContext()
      context.interactionNotAllowed = true
      query[kSecUseAuthenticationContext as String] = context
    }
    return query
  }
}

public enum KeychainTokenStoreError: LocalizedError, Equatable {
  case invalidData
  case invalidCredentialOrigin(String)
  case unhandledStatus(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidData:
      return CoreL10n.text("Keychain 返回了不可解析的 token 数据。")
    case .invalidCredentialOrigin(let value):
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return CoreL10n.text("API Base URL 尚未配置。")
      }
      return CoreL10n.format("凭据端点必须是有效的 HTTPS 地址：%@", value)
    case .unhandledStatus(let status):
      return CoreL10n.format(
        "Keychain 操作失败：%@（错误码 %@）",
        Self.statusDescription(for: status),
        String(status)
      )
    }
  }

  public var recoveryHint: String? {
    switch self {
    case .invalidData:
      return CoreL10n.text("请检查该服务在钥匙串中的记录是否损坏，可删除后重新保存 Token。")
    case .invalidCredentialOrigin:
      return CoreL10n.text("请先修正 API Base URL；端点变化后需要重新保存对应 Token。")
    case .unhandledStatus(let status):
      switch status {
      case errSecInteractionNotAllowed:
        return CoreL10n.text("系统当前禁止了本应用的钥匙串访问。请前往“系统设置” → “隐私与安全性” → “钥匙串”，允许本应用访问该服务后重试。")
      case errSecAuthFailed:
        return CoreL10n.text("钥匙串认证失败。可尝试重启电脑或重新登录系统后重试。")
      case errSecNoSuchKeychain:
        return CoreL10n.text("应用未连接到登录钥匙串。请使用项目的统一启动脚本重新启动；若仍失败，请在“钥匙串访问”中确认 login 钥匙串可用。")
      case errSecInvalidOwnerEdit, -25253:
        return CoreL10n.text("当前本地构建无法继续使用旧构建创建的钥匙串访问上下文。请重启最新构建后重新保存；如果仍失败，可在“钥匙串访问”中删除对应的 PersonalSitePublisher 旧项后再保存。")
      case errSecItemNotFound:
        return CoreL10n.text("对应 Profile 的钥匙串条目不存在，请先点击“保存”写入 Token。")
      case errSecUserCanceled:
        return CoreL10n.text("你已取消了系统授权提示，请重新触发操作并在授权弹窗中选择允许。")
      default:
        return nil
      }
    }
  }

  public var recoverySuggestion: String? {
    recoveryHint
  }

  private static func statusDescription(for status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) {
      return "\(message)"
    }
    return CoreL10n.text("未知错误")
  }
}
