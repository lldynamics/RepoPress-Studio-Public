import Foundation

public enum AICredentialStorageMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case localFile
  case keychain
  case session

  public var id: String { rawValue }
}

/// Stores AI credentials independently from repository and deployment tokens.
///
/// Production builds default to a restricted local configuration file. Keychain
/// access only occurs after the user explicitly selects the Keychain mode.
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
        defaultMode: .localFile
      )
    }
  }

  public init(
    keychainTokenStore: KeychainTokenStore,
    localFileURL: URL,
    userDefaults: UserDefaults? = nil,
    preferenceKey: String = AICredentialStore.storageModePreferenceKey,
    defaultMode: AICredentialStorageMode = .localFile,
    fileManager: FileManager = .default
  ) {
    self.keychainTokenStore = keychainTokenStore
    self.localFileURL = localFileURL
    self.userDefaults = userDefaults
    self.preferenceKey = preferenceKey
    self.defaultMode = defaultMode
    self.fileManager = fileManager
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
        if selectedModeHasCurrentGeneration(for: id) {
          if let shared = try keychainTokenStore
            .aiToken(forConnectionProfileID: id)?.nilIfEmpty {
            return shared
          }
        }
        // Legacy Keychain items are origin-bound. Even after a connection ID
        // is invalidated, looking up the current origin cannot send an old key
        // to a newly selected endpoint and preserves external restores.
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
              credential.token.nilIfEmpty != nil else {
          return KeychainTokenAvailability(hasToken: false)
        }
        return KeychainTokenAvailability(hasToken: true, updatedAt: credential.updatedAt)
      case .keychain:
        if selectedModeHasCurrentGeneration(for: id) {
          let shared = try keychainTokenStore.aiTokenAvailability(
            forConnectionProfileID: id
          )
          if shared.hasToken || shared.accessFailureMessage != nil {
            return shared
          }
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
              credential.token.nilIfEmpty != nil else {
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
        var document = try localDocument()
        document.credentials.removeValue(forKey: id.uuidString)
        try writeLocalDocument(document)
      case .keychain:
        try keychainTokenStore.deleteAIToken(forConnectionProfileID: id)
        for profile in legacyProfiles {
          _ = try? keychainTokenStore.deleteLegacyAIToken(for: profile)
        }
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
      try deleteToken(
        forConnectionProfileID: id,
        legacyProfiles: legacyProfiles
      )
      setCredentialGeneration(credentialGeneration(for: id) + 1, for: id)
    }
  }

  private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }

  private func resolvedStorageMode() -> AICredentialStorageMode {
    if let userDefaults,
       let rawValue = userDefaults.string(forKey: preferenceKey),
       let mode = AICredentialStorageMode(rawValue: rawValue) {
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
      let data = try Data(contentsOf: localFileURL)
      let document = try JSONDecoder().decode(LocalCredentialDocument.self, from: data)
      guard document.version == LocalCredentialDocument.currentVersion else {
        throw AICredentialStoreError.unsupportedLocalFileVersion(document.version)
      }
      try applyRestrictedPermissionsToExistingFile()
      return document
    } catch let error as AICredentialStoreError {
      throw error
    } catch {
      throw AICredentialStoreError.unreadableLocalFile(error.localizedDescription)
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
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      var mutableDirectoryURL = directoryURL
      try? mutableDirectoryURL.setResourceValues(resourceValues)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(document)
      try data.write(to: localFileURL, options: .atomic)
      try applyRestrictedPermissionsToExistingFile()
    } catch let error as AICredentialStoreError {
      throw error
    } catch {
      throw AICredentialStoreError.unwritableLocalFile(error.localizedDescription)
    }
  }

  private func applyRestrictedPermissionsToExistingFile() throws {
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: localFileURL.path
    )
  }

  private static func defaultLocalFileURL() -> URL {
    let supportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return supportURL
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
    case .unreadableLocalFile(let detail):
      return CoreL10n.format("本地 AI 凭据配置无法读取：%@", detail)
    case .unwritableLocalFile(let detail):
      return CoreL10n.format("本地 AI 凭据配置无法写入：%@", detail)
    case .unsupportedLocalFileVersion(let version):
      return CoreL10n.format("本地 AI 凭据配置版本不受支持：%@", String(version))
    }
  }
}
