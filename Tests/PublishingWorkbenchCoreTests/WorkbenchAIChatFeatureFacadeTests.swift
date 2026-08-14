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
}
