import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAIChatFeatureFacadeTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ai-chat-facade-\(UUID().uuidString).json")
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }

  func testPublishesChatStateButIgnoresUnrelatedStoreState() {
    let store = makeStore()
    let facade = WorkbenchAIChatFeatureFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("流式状态")
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "回复")
    ])
    store.setAIChatRunning(true)
    XCTAssertEqual(changes, 3)

    store.setAIActionMessage("不属于聊天检查器")
    store.siteMaintenanceStore.setRefreshing(true)
    store.setImageActionMessage("图片处理")
    XCTAssertEqual(changes, 3)

    withExtendedLifetime(cancellable) {}
  }

  func testRemovesDuplicateChatValues() {
    let store = makeStore()
    let facade = WorkbenchAIChatFeatureFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("相同状态")
    store.setAIChatMessage("相同状态")
    XCTAssertEqual(changes, 1)

    withExtendedLifetime(cancellable) {}
  }

  func testPublishesQuickSwitchModelTokenAndConnectionProjection() throws {
    let store = makeStore()
    let facade = WorkbenchAIChatFeatureFacade(store: store)
    let draft = try XCTUnwrap(store.drafts.first)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatCustomModel("projection-model")

    XCTAssertEqual(facade.chatModelGrade, .custom)
    XCTAssertEqual(facade.chatSelectedModel, "projection-model")
    XCTAssertEqual(
      facade.chatProviderConfig(for: draft),
      facade.activeChatConnectionProfile.config
    )
    XCTAssertGreaterThan(changes, 0)

    let beforeTokenChange = changes
    store.setAITokenAvailability(KeychainTokenAvailability(hasToken: true))
    XCTAssertTrue(facade.tokenAvailability.hasToken)
    XCTAssertGreaterThan(changes, beforeTokenChange)

    let beforeConnectionChange = changes
    var updatedConnection = facade.activeChatConnectionProfile
    updatedConnection.config.model = "connection-model"
    XCTAssertTrue(store.updateAIConnectionProfile(updatedConnection))

    XCTAssertEqual(
      facade.activeChatConnectionProfile.config.normalizedModel,
      "connection-model"
    )
    XCTAssertEqual(
      facade.chatProviderConfig(for: draft).normalizedModel,
      "connection-model"
    )
    XCTAssertGreaterThan(changes, beforeConnectionChange)

    withExtendedLifetime(cancellable) {}
  }
}
