import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreAIKeyStorageTests: XCTestCase {
  func testSaveAIAPIKeyStoresTokenAndUpdatesAvailability() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchStoreAIKeyStorageTests-\(UUID().uuidString)")
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKey.\(UUID().uuidString)",
      accountPrefix: "ai-key-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )

    store.saveAIAPIKey("  sk-test-token  ")

    XCTAssertEqual(store.aiActionMessage, "AI API Key 已保存到 Keychain。")
    XCTAssertTrue(store.aiTokenAvailability.hasToken)
    XCTAssertEqual(try tokenStore.aiToken(for: store.activeProfile), "sk-test-token")
  }

  func testDeleteAIAPIKeyClearsStoredTokenAndAvailability() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchStoreAIKeyDeleteTests-\(UUID().uuidString)")
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKey.\(UUID().uuidString)",
      accountPrefix: "ai-key-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )
    store.saveAIAPIKey("sk-test-token")

    store.deleteAIAPIKey()

    XCTAssertEqual(store.aiActionMessage, "AI API Key 已删除。")
    XCTAssertFalse(store.aiTokenAvailability.hasToken)
    XCTAssertNil(try tokenStore.aiToken(for: store.activeProfile))
  }

  func testChangingAIEndpointRequiresTokenToBeSavedAgain() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchStoreAIOriginTests-\(UUID().uuidString)")
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIOrigin.\(UUID().uuidString)",
      accountPrefix: "ai-origin-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )
    store.saveAIAPIKey("deepseek-token")
    XCTAssertTrue(store.aiTokenAvailability.hasToken)

    store.updateActiveProfile { profile in
      profile.aiProviderConfig.baseURL = "https://ai-proxy.example/v1"
    }
    store.refreshAIKeyAvailability()

    XCTAssertFalse(store.aiTokenAvailability.hasToken)
    XCTAssertNil(try tokenStore.aiToken(for: store.activeProfile))
  }
}
