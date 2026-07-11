import Foundation
import LocalAuthentication
import Security

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
  private var inMemoryTokens: [String: String]?

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
    self.inMemoryTokens = inMemory ? [:] : nil
  }

  public func token(for profile: SiteProfile) throws -> String? {
    try token(forAccount: account(for: profile))
  }

  public func token(for profile: SiteProfile, scope: KeychainTokenScope) throws -> String? {
    try token(forAccount: account(for: profile, scope: scope))
  }

  public func repositoryToken(for profile: SiteProfile) throws -> String? {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    _ = try migrateLegacyToken(for: profile, to: scope, deleteLegacyToken: false)
    return try token(for: profile, scope: scope)
  }

  public func availability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    try availability(forAccount: account(for: profile))
  }

  public func availability(for profile: SiteProfile, scope: KeychainTokenScope) throws -> KeychainTokenAvailability {
    try availability(forAccount: account(for: profile, scope: scope))
  }

  public func repositoryTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    let scope = KeychainTokenScope.repository(profile.repositoryProvider)
    _ = try migrateLegacyToken(for: profile, to: scope, deleteLegacyToken: false)
    return try availability(for: profile, scope: scope)
  }

  public func saveToken(_ token: String, for profile: SiteProfile) throws {
    try saveToken(token, forAccount: account(for: profile))
  }

  public func saveToken(_ token: String, for profile: SiteProfile, scope: KeychainTokenScope) throws {
    try saveToken(token, forAccount: account(for: profile, scope: scope))
  }

  public func deleteToken(for profile: SiteProfile) throws {
    try deleteToken(forAccount: account(for: profile))
  }

  public func deleteToken(for profile: SiteProfile, scope: KeychainTokenScope) throws {
    try deleteToken(forAccount: account(for: profile, scope: scope))
  }

  @discardableResult
  public func migrateLegacyToken(
    for profile: SiteProfile,
    to scope: KeychainTokenScope,
    deleteLegacyToken: Bool = true
  ) throws -> Bool {
    guard try token(for: profile, scope: scope) == nil,
          let legacyToken = try token(for: profile) else {
      return false
    }
    try saveToken(legacyToken, for: profile, scope: scope)
    if deleteLegacyToken {
      try deleteToken(for: profile)
    }
    return true
  }

  private func token(forAccount account: String) throws -> String? {
    if let inMemoryTokens {
      return inMemoryTokens[account]
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
    if let inMemoryTokens {
      return KeychainTokenAvailability(hasToken: inMemoryTokens[account] != nil)
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
    if inMemoryTokens != nil {
      inMemoryTokens?[account] = token
      return
    }

    let data = Data(token.utf8)
    var query = baseQuery(account: account)

    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
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
    guard addStatus == errSecSuccess else {
      throw KeychainTokenStoreError.unhandledStatus(addStatus)
    }
  }

  private func deleteToken(forAccount account: String) throws {
    if inMemoryTokens != nil {
      inMemoryTokens?.removeValue(forKey: account)
      return
    }

    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainTokenStoreError.unhandledStatus(status)
    }
  }

  private func account(for profile: SiteProfile) -> String {
    "\(accountPrefix)-\(profile.id.uuidString)"
  }

  private func account(for profile: SiteProfile, scope: KeychainTokenScope) -> String {
    "\(account(for: profile))-\(scope.accountComponent)"
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
  case unhandledStatus(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidData:
      return "Keychain 返回了不可解析的 token 数据。"
    case .unhandledStatus(let status):
      return "Keychain 操作失败：\(Self.statusDescription(for: status))（错误码 \(status)）"
    }
  }

  public var recoveryHint: String? {
    switch self {
    case .invalidData:
      return "请检查该服务在钥匙串中的记录是否损坏，可删除后重新保存 Token。"
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
