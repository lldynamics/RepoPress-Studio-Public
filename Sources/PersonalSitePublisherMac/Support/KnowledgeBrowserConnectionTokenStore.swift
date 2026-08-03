import Foundation
import PublishingWorkbenchCore

struct KnowledgeBrowserConnectionTokenStore {
  private static let accountIdentifier = "connection-token-v1"

  private let keychain: KeychainTokenStore

  init(
    keychain: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.browserBridge,
      accountPrefix: "browser-bridge"
    )
  ) {
    self.keychain = keychain
  }

  func token() throws -> String? {
    guard let token = try keychain.token(forAccountIdentifier: Self.accountIdentifier) else {
      return nil
    }
    guard !token.isEmpty else {
      throw KnowledgeBrowserConnectionTokenStoreError.invalidData
    }
    return token
  }

  func persist(_ token: String) throws {
    guard !token.isEmpty else {
      throw KnowledgeBrowserConnectionTokenStoreError.invalidData
    }
    try keychain.saveToken(token, forAccountIdentifier: Self.accountIdentifier)
  }
}

enum KnowledgeBrowserConnectionTokenStoreError: LocalizedError, Equatable {
  case invalidData

  var errorDescription: String? {
    switch self {
    case .invalidData:
      return "Keychain 中的浏览器连接令牌内容无效。"
    }
  }
}
