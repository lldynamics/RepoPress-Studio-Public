import Foundation
import PublishingWorkbenchCore

struct KnowledgeBrowserConnectionTokenDefaults: @unchecked Sendable {
  let value: UserDefaults

  init(_ value: UserDefaults) {
    self.value = value
  }
}

struct KnowledgeBrowserConnectionTokenStore {
  private let fileURL: URL?
  private let defaults: UserDefaults
  private let legacyDefaultsKey: String

  init(
    fileURL: URL?,
    defaults: KnowledgeBrowserConnectionTokenDefaults,
    legacyDefaultsKey: String
  ) {
    self.fileURL = fileURL
    self.defaults = defaults.value
    self.legacyDefaultsKey = legacyDefaultsKey
  }

  func token() throws -> String? {
    guard let fileURL else {
      return defaults.string(forKey: legacyDefaultsKey)
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return defaults.string(forKey: legacyDefaultsKey)
    }

    let data = try BoundedFileReader.data(
      at: fileURL,
      maximumByteCount: 4_096
    )
    guard let token = String(data: data, encoding: .utf8),
          !token.isEmpty else {
      throw KnowledgeBrowserConnectionTokenStoreError.invalidData
    }
    return token
  }

  func persist(_ token: String) throws {
    guard !token.isEmpty else {
      throw KnowledgeBrowserConnectionTokenStoreError.invalidData
    }
    guard let fileURL else {
      defaults.set(token, forKey: legacyDefaultsKey)
      return
    }

    let directoryURL = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
    try Data(token.utf8).write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
    defaults.removeObject(forKey: legacyDefaultsKey)
  }
}

enum KnowledgeBrowserConnectionTokenStoreError: LocalizedError {
  case invalidData

  var errorDescription: String? {
    switch self {
    case .invalidData:
      return "浏览器连接令牌文件内容无效。"
    }
  }
}
