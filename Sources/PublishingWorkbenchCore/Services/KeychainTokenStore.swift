import Foundation
import LocalAuthentication
import Security

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

public struct KeychainTokenAvailability: Codable, Hashable, Sendable {
  public var hasToken: Bool
  public var updatedAt: Date?

  public init(hasToken: Bool, updatedAt: Date? = nil) {
    self.hasToken = hasToken
    self.updatedAt = updatedAt
  }
}

public enum KeychainTokenScope: Hashable, Sendable {
  case repository(RepositoryProvider)
  case deployment(DeploymentProvider)

  var accountComponent: String {
    switch self {
    case .repository(let provider):
      return "repository-\(provider.rawValue)"
    case .deployment(let provider):
      return "deployment-\(provider.rawValue)"
    }
  }
}

public final class KeychainTokenStore: @unchecked Sendable {
  private let service: String
  private let accountPrefix: String
  private let allowsAuthenticationInteraction: Bool
  private let inMemoryBackend: InMemoryTokenBackend?

  public convenience init(
    service: String = "PersonalSitePublisherMac.AIProvider",
    accountPrefix: String = "ai-provider"
  ) {
    self.init(service: service, accountPrefix: accountPrefix, inMemory: false)
  }

  public init(
    service: String,
    accountPrefix: String,
    inMemory: Bool = false,
    allowsAuthenticationInteraction: Bool = true
  ) {
    self.service = service
    self.accountPrefix = accountPrefix
    self.allowsAuthenticationInteraction = allowsAuthenticationInteraction
    self.inMemoryBackend = inMemory ? InMemoryTokenBackend() : nil
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
    try token(forAccount: aiCredentialAccount(for: profile))
  }

  public func repositoryToken(for profile: SiteProfile) throws -> String? {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    return try token(
      for: profile,
      scope: scope,
      originURLText: repositoryOriginURLText(for: profile)
    )
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
    try availability(forAccount: aiCredentialAccount(for: profile))
  }

  public func repositoryTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    return try availability(
      for: profile,
      scope: scope,
      originURLText: repositoryOriginURLText(for: profile)
    )
  }

  public func saveRepositoryToken(_ token: String, for profile: SiteProfile) throws {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      try saveToken(
        token,
        for: profile,
        scope: .repository(profile.repositoryProvider),
        originURLText: repositoryOriginURLText(for: profile)
      )
      try deleteToken(for: profile, scope: .repository(profile.repositoryProvider))
      try deleteToken(for: profile)
    }
  }

  public func deleteRepositoryToken(for profile: SiteProfile) throws {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      try deleteToken(
        for: profile,
        scope: .repository(profile.repositoryProvider),
        originURLText: repositoryOriginURLText(for: profile)
      )
      try deleteToken(for: profile, scope: .repository(profile.repositoryProvider))
      // Older releases left this unscoped credential behind after migration.
      // Remove it in the same critical section so availability refresh cannot
      // recreate the scoped credential that the user just deleted.
      try deleteToken(for: profile)
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

  public func saveAIToken(_ token: String, for profile: SiteProfile) throws {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      try saveToken(token, forAccount: aiCredentialAccount(for: profile))
      try deleteToken(for: profile)
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

  public func deleteAIToken(for profile: SiteProfile) throws {
    try KeychainTokenMutationCoordinator.shared.synchronized {
      try deleteToken(forAccount: aiCredentialAccount(for: profile))
      try deleteToken(for: profile)
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

    var query = baseQuery(account: account)
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

    var query = baseQuery(account: account)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return KeychainTokenAvailability(hasToken: false)
    }
    guard status == errSecSuccess else {
      throw KeychainTokenStoreError.unhandledStatus(status)
    }

    let attributes = result as? [String: Any]
    return KeychainTokenAvailability(
      hasToken: true,
      updatedAt: attributes?[kSecAttrModificationDate as String] as? Date
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
      if let inMemoryBackend {
        inMemoryBackend.deleteToken(for: account)
        return
      }

      let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainTokenStoreError.unhandledStatus(status)
      }
    }
  }

  private func account(for profile: SiteProfile) -> String {
    "\(accountPrefix)-\(profile.id.uuidString)"
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
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if allowsAuthenticationInteraction {
      let context = LAContext()
      context.interactionNotAllowed = false
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
      return "Keychain 返回了不可解析的 token 数据。"
    case .invalidCredentialOrigin(let value):
      return "凭据端点必须是有效的 HTTPS 地址：\(value)"
    case .unhandledStatus(let status):
      return "Keychain 操作失败：\(Self.statusDescription(for: status))（错误码 \(status)）"
    }
  }

  public var recoveryHint: String? {
    switch self {
    case .invalidData:
      return "请检查该服务在钥匙串中的记录是否损坏，可删除后重新保存 Token。"
    case .invalidCredentialOrigin:
      return "请先修正 API Base URL；端点变化后需要重新保存对应 Token。"
    case .unhandledStatus(let status):
      switch status {
      case errSecInteractionNotAllowed:
        return "系统当前禁止了本应用的钥匙串访问。请前往“系统设置” → “隐私与安全性” → “钥匙串”，允许本应用访问该服务后重试。"
      case errSecAuthFailed:
        return "钥匙串认证失败。可尝试重启电脑或重新登录系统后重试。"
      case errSecItemNotFound:
        return "对应 Profile 的钥匙串条目不存在，请先点击“保存”写入 Token。"
      case errSecUserCanceled:
        return "你已取消了系统授权提示，请重新触发操作并在授权弹窗中选择允许。"
      default:
        return nil
      }
    }
  }

  private static func statusDescription(for status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) {
      return "\(message)"
    }
    return "未知错误"
  }
}
