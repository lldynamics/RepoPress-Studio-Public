import Foundation

public enum AICredentialStorageMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable
{
  case localFile
  case keychain
  case session

  public var id: String { rawValue }
}

/// Stores AI credentials independently from repository and deployment tokens.
///
/// Production builds default to macOS Keychain. A previously persisted
/// `.localFile` choice remains honored, but an existing legacy file is never
/// imported automatically. Keychain, local-file, and session sources stay
/// isolated unless the user explicitly selects a source.
public final class AICredentialStore: @unchecked Sendable {
  public static let storageModePreferenceKey = "ai.credentialStorageMode"

  private struct StoredCredential: Codable {
    var token: String
    var updatedAt: Date
  }

  private struct LocalCredentialDocument: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var credentials: [String: StoredCredential] = [:]
  }

  private let keychainTokenStore: KeychainTokenStore
  private let localFileURL: URL
  private let userDefaults: UserDefaults?
  private let preferenceKey: String
  private let defaultMode: AICredentialStorageMode
  private let fileManager: FileManager
  private let backupExclusionHandler: (URL) throws -> Void
  private let lock = NSRecursiveLock()
  private var transientMode: AICredentialStorageMode?
  private var sessionCredentials: [UUID: StoredCredential] = [:]
  private var transientGenerations: [String: Int] = [:]

  public convenience init(keychainTokenStore: KeychainTokenStore) {
    if keychainTokenStore.usesInMemoryBackend {
      self.init(
        keychainTokenStore: keychainTokenStore,
        localFileURL: Self.defaultLocalFileURL(),
        userDefaults: nil,
        defaultMode: .keychain
      )
    } else {
      self.init(
        keychainTokenStore: keychainTokenStore,
        localFileURL: Self.defaultLocalFileURL(),
        userDefaults: .standard,
        defaultMode: .keychain
      )
    }
  }

  public convenience init(
    keychainTokenStore: KeychainTokenStore,
    localFileURL: URL,
    userDefaults: UserDefaults? = nil,
    preferenceKey: String = AICredentialStore.storageModePreferenceKey,
    defaultMode: AICredentialStorageMode = .keychain,
    fileManager: FileManager = .default
  ) {
    self.init(
      keychainTokenStore: keychainTokenStore,
      localFileURL: localFileURL,
      userDefaults: userDefaults,
      preferenceKey: preferenceKey,
      defaultMode: defaultMode,
      fileManager: fileManager,
      backupExclusionHandler: Self.applyBackupExclusion
    )
  }

  init(
    keychainTokenStore: KeychainTokenStore,
    localFileURL: URL,
    userDefaults: UserDefaults?,
    preferenceKey: String = AICredentialStore.storageModePreferenceKey,
    defaultMode: AICredentialStorageMode,
    fileManager: FileManager,
    backupExclusionHandler: @escaping (URL) throws -> Void
  ) {
    self.keychainTokenStore = keychainTokenStore
    self.localFileURL = localFileURL
    self.userDefaults = userDefaults
    self.preferenceKey = preferenceKey
    self.defaultMode = defaultMode
    self.fileManager = fileManager
    self.backupExclusionHandler = backupExclusionHandler
  }

  public var storageMode: AICredentialStorageMode {
    lock.lock()
    defer { lock.unlock() }
    return resolvedStorageMode()
  }

  /// Changes the active source without reading, copying, or deleting a secret.
  /// This keeps switching to or from Keychain an explicit, prompt-free setting
  /// operation. The user can then save or delete the key in the selected source.
  public func setStorageMode(_ mode: AICredentialStorageMode) {
    lock.lock()
    defer { lock.unlock() }
    if let userDefaults {
      userDefaults.set(mode.rawValue, forKey: preferenceKey)
    } else {
      transientMode = mode
    }
  }

  public func token(
    forConnectionProfileID id: UUID,
    legacyProfile: SiteProfile? = nil
  ) throws -> String? {
    try synchronized {
      switch resolvedStorageMode() {
      case .localFile:
        guard selectedModeHasCurrentGeneration(for: id) else { return nil }
        return try localDocument().credentials[id.uuidString]?.token.nilIfEmpty
      case .keychain:
        // A generation mismatch is a fail-closed boundary. In particular, do
        // not fall back to an origin-bound legacy item after an endpoint or
        // identity change, even if that item is still present in Keychain.
        guard selectedModeHasCurrentGeneration(for: id) else { return nil }
        if let shared = try keychainTokenStore
          .aiToken(forConnectionProfileID: id)?.nilIfEmpty
        {
          return shared
        }
        // Legacy Keychain items are origin-bound and are only consulted while
        // the connection identity is still current. This preserves compatible
        // restores without allowing an invalidated credential to reactivate.
        guard let legacyProfile else { return nil }
        return try keychainTokenStore.aiToken(for: legacyProfile)?.nilIfEmpty
      case .session:
        guard selectedModeHasCurrentGeneration(for: id) else { return nil }
        return sessionCredentials[id]?.token.nilIfEmpty
      }
    }
  }

  public func availability(
    forConnectionProfileID id: UUID,
    legacyProfile: SiteProfile? = nil
  ) throws -> KeychainTokenAvailability {
    try synchronized {
      switch resolvedStorageMode() {
      case .localFile:
        guard selectedModeHasCurrentGeneration(for: id) else {
          return KeychainTokenAvailability(hasToken: false)
        }
        guard let credential = try localDocument().credentials[id.uuidString],
          credential.token.nilIfEmpty != nil
        else {
          return KeychainTokenAvailability(hasToken: false)
        }
        return KeychainTokenAvailability(hasToken: true, updatedAt: credential.updatedAt)
      case .keychain:
        // Match token() and fail closed before consulting any legacy source.
        guard selectedModeHasCurrentGeneration(for: id) else {
          return KeychainTokenAvailability(hasToken: false)
        }
        let shared = try keychainTokenStore.aiTokenAvailability(
          forConnectionProfileID: id
        )
        if shared.hasToken || shared.accessFailureMessage != nil {
          return shared
        }
        guard let legacyProfile else {
          return KeychainTokenAvailability(hasToken: false)
        }
        return try keychainTokenStore.aiTokenAvailability(for: legacyProfile)
      case .session:
        guard selectedModeHasCurrentGeneration(for: id) else {
          return KeychainTokenAvailability(hasToken: false)
        }
        guard let credential = sessionCredentials[id],
          credential.token.nilIfEmpty != nil
        else {
          return KeychainTokenAvailability(hasToken: false)
        }
        return KeychainTokenAvailability(hasToken: true, updatedAt: credential.updatedAt)
      }
    }
  }

  public func saveToken(
    _ token: String,
    forConnectionProfileID id: UUID,
    legacyProfile: SiteProfile? = nil
  ) throws {
    try synchronized {
      let normalizedToken = token.trimmedForPublishing
      guard !normalizedToken.isEmpty else {
        throw AICredentialStoreError.emptyToken
      }
      let credential = StoredCredential(token: normalizedToken, updatedAt: Date())
      switch resolvedStorageMode() {
      case .localFile:
        var document = try localDocument()
        document.credentials[id.uuidString] = credential
        try writeLocalDocument(document)
      case .keychain:
        try keychainTokenStore.saveAIToken(
          normalizedToken,
          forConnectionProfileID: id
        )
        if let legacyProfile {
          _ = try? keychainTokenStore.deleteLegacyAIToken(for: legacyProfile)
        }
      case .session:
        sessionCredentials[id] = credential
      }
      markSelectedModeCurrent(for: id)
    }
  }

  public func deleteToken(
    forConnectionProfileID id: UUID,
    legacyProfiles: [SiteProfile] = []
  ) throws {
    try synchronized {
      switch resolvedStorageMode() {
      case .localFile:
        guard fileManager.fileExists(atPath: localFileURL.path) else { return }
        var document = try localDocument()
        document.credentials.removeValue(forKey: id.uuidString)
        try writeLocalDocument(document)
      case .keychain:
        // Clear origin-bound legacy items first. If Keychain rejects that
        // cleanup, leave the shared credential untouched so callers can abort
        // an endpoint edit without losing the key for the existing endpoint.
        for profile in legacyProfiles {
          try keychainTokenStore.deleteLegacyAIToken(for: profile)
        }
        try keychainTokenStore.deleteAIToken(forConnectionProfileID: id)
      case .session:
        sessionCredentials.removeValue(forKey: id)
      }
    }
  }

  /// Legacy Keychain cleanup is deliberately disabled outside Keychain mode.
  public func deleteLegacyTokenIfKeychainIsSelected(for profile: SiteProfile) throws {
    try synchronized {
      guard resolvedStorageMode() == .keychain else { return }
      try keychainTokenStore.deleteLegacyAIToken(for: profile)
    }
  }

  /// Invalidates every storage mode without reading or mutating inactive
  /// sources. This prevents an API key saved for an old endpoint from becoming
  /// active again after the user changes the endpoint and later switches modes.
  public func invalidateTokenAcrossStorageModes(
    forConnectionProfileID id: UUID,
    legacyProfiles: [SiteProfile] = []
  ) throws {
    try synchronized {
      if resolvedStorageMode() == .keychain {
        // A Codex connection uses a loopback sentinel as an internal
        // transport identity. It never had an origin-bound legacy Keychain
        // item, so asking the Keychain store to construct that account is
        // expected to fail with `invalidCredentialOrigin`. Treat only this
        // exact, known-impossible legacy shape as absent; all other errors
        // remain fail-closed and prevent the shared credential from being
        // removed behind the caller's back.
        for profile in legacyProfiles {
          do {
            try keychainTokenStore.deleteLegacyAIToken(for: profile)
          } catch {
            guard
              let keychainError = error as? KeychainTokenStoreError,
              case .invalidCredentialOrigin = keychainError,
              Self.isLegacyCodexSentinel(profile)
            else {
              throw error
            }
          }
        }
        try keychainTokenStore.deleteAIToken(forConnectionProfileID: id)
      } else {
        try deleteToken(
          forConnectionProfileID: id,
          legacyProfiles: legacyProfiles
        )
      }
      setCredentialGeneration(credentialGeneration(for: id) + 1, for: id)
    }
  }

  private static func isLegacyCodexSentinel(_ profile: SiteProfile) -> Bool {
    let config = profile.aiProviderConfig
    return
      (config.preset == .custom || config.preset == .codexAppServer)
      && config.baseURL == AIProviderPreset.codexAppServer.defaultBaseURL
      && !config.requiresAPIKey
  }

  private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }

  private func resolvedStorageMode() -> AICredentialStorageMode {
    if let userDefaults,
      let rawValue = userDefaults.string(forKey: preferenceKey),
      let mode = AICredentialStorageMode(rawValue: rawValue)
    {
      return mode
    }
    return transientMode ?? defaultMode
  }

  private func selectedModeHasCurrentGeneration(for id: UUID) -> Bool {
    modeGeneration(for: resolvedStorageMode(), connectionProfileID: id)
      == credentialGeneration(for: id)
  }

  private func markSelectedModeCurrent(for id: UUID) {
    setModeGeneration(
      credentialGeneration(for: id),
      for: resolvedStorageMode(),
      connectionProfileID: id
    )
  }

  private func credentialGeneration(for id: UUID) -> Int {
    storedInteger(forKey: generationKey(for: id))
  }

  private func setCredentialGeneration(_ generation: Int, for id: UUID) {
    setStoredInteger(generation, forKey: generationKey(for: id))
  }

  private func modeGeneration(
    for mode: AICredentialStorageMode,
    connectionProfileID id: UUID
  ) -> Int {
    storedInteger(forKey: modeGenerationKey(for: mode, connectionProfileID: id))
  }

  private func setModeGeneration(
    _ generation: Int,
    for mode: AICredentialStorageMode,
    connectionProfileID id: UUID
  ) {
    setStoredInteger(
      generation,
      forKey: modeGenerationKey(for: mode, connectionProfileID: id)
    )
  }

  private func storedInteger(forKey key: String) -> Int {
    if let userDefaults {
      return userDefaults.integer(forKey: key)
    }
    return transientGenerations[key] ?? 0
  }

  private func setStoredInteger(_ value: Int, forKey key: String) {
    if let userDefaults {
      userDefaults.set(value, forKey: key)
    } else {
      transientGenerations[key] = value
    }
  }

  private func generationKey(for id: UUID) -> String {
    "ai.credentialGeneration.\(id.uuidString.lowercased())"
  }

  private func modeGenerationKey(
    for mode: AICredentialStorageMode,
    connectionProfileID id: UUID
  ) -> String {
    "ai.credentialGeneration.\(mode.rawValue).\(id.uuidString.lowercased())"
  }

  private func localDocument() throws -> LocalCredentialDocument {
    guard fileManager.fileExists(atPath: localFileURL.path) else {
      return LocalCredentialDocument()
    }
    do {
      // Tighten permissions and backup metadata when an explicitly selected
      // legacy file is read. This is a compatibility repair only; it never
      // migrates, copies, or removes the user's existing credential file.
      try applyRestrictedPermissionsToExistingFile()
      let data = try Data(contentsOf: localFileURL)
      let document = try JSONDecoder().decode(LocalCredentialDocument.self, from: data)
      guard document.version == LocalCredentialDocument.currentVersion else {
        throw AICredentialStoreError.unsupportedLocalFileVersion(document.version)
      }
      return document
    } catch let error as AICredentialStoreError {
      throw error
    } catch {
      // Do not retain Foundation's underlying description: malformed input or
      // a file-system error must never echo credential-bearing data.
      throw AICredentialStoreError.unreadableLocalFile("读取失败")
    }
  }

  private func writeLocalDocument(_ document: LocalCredentialDocument) throws {
    do {
      let directoryURL = localFileURL.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: directoryURL.path
      )
      try excludeFromBackup(directoryURL)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(document)
      try data.write(to: localFileURL, options: .atomic)
      try applyRestrictedPermissionsToExistingFile()
    } catch let error as AICredentialStoreError {
      throw error
    } catch {
      // Keep the public error useful without exposing paths or secret values
      // that an underlying Foundation error might contain.
      throw AICredentialStoreError.unwritableLocalFile("写入失败")
    }
  }

  private func applyRestrictedPermissionsToExistingFile() throws {
    let directoryURL = localFileURL.deletingLastPathComponent()
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: directoryURL.path
    )
    try excludeFromBackup(directoryURL)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: localFileURL.path
    )
    try excludeFromBackup(localFileURL)
  }

  private func excludeFromBackup(_ url: URL) throws {
    try backupExclusionHandler(url)
  }

  private static func applyBackupExclusion(_ url: URL) throws {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(resourceValues)
  }

  private static func defaultLocalFileURL() -> URL {
    let supportURL =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return
      supportURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("AI", isDirectory: true)
      .appendingPathComponent("credentials.json", isDirectory: false)
  }
}

public enum AICredentialStoreError: LocalizedError, Equatable {
  case emptyToken
  case unreadableLocalFile(String)
  case unwritableLocalFile(String)
  case unsupportedLocalFileVersion(Int)

  public var errorDescription: String? {
    switch self {
    case .emptyToken:
      return CoreL10n.text("API Key 不能为空。")
    case .unreadableLocalFile:
      return CoreL10n.text("本地 AI 凭据配置无法读取，请检查权限或选择其他保存位置。")
    case .unwritableLocalFile:
      return CoreL10n.text("本地 AI 凭据配置无法写入，请检查权限或选择其他保存位置。")
    case .unsupportedLocalFileVersion(let version):
      return CoreL10n.format("本地 AI 凭据配置版本不受支持：%@", String(version))
    }
  }
}
