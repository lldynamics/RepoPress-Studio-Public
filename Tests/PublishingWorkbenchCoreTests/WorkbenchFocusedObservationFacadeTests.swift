import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchFocusedObservationFacadeTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "focused-observation-" + UUID().uuidString + ".json"
      )
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }

  func testMetadataSummaryFacadePublishesOnlyRelevantState() {
    let store = makeStore()
    let facade = WorkbenchMetadataSummaryFeatureFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("流式状态")
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "流式 token")
    ])
    store.setImageActionMessage("图片处理状态")
    store.siteMaintenanceStore.setRefreshing(true)
    store.siteMaintenanceStore.setRefreshErrorMessage("维护状态")
    XCTAssertEqual(changes, 0)

    store.setAIActionMessage("摘要动作状态")
    XCTAssertEqual(changes, 1)
    store.setAIActionMessage("摘要动作状态")
    XCTAssertEqual(changes, 1)

    store.aiWorkspaceStore.isAIActionRunning = true
    XCTAssertEqual(changes, 2)
    store.setAITokenAvailability(KeychainTokenAvailability(hasToken: true))
    XCTAssertEqual(changes, 3)
    XCTAssertTrue(facade.tokenAvailability.hasToken)
    XCTAssertTrue(facade.isActionRunning)
    XCTAssertEqual(facade.actionMessage, "摘要动作状态")

    var profiles = store.profiles
    XCTAssertFalse(profiles.isEmpty)
    profiles[0].name += "-unrelated"
    store.setProfiles(profiles)
    XCTAssertEqual(changes, 3)

    profiles[0].aiProviderConfig.model += "-changed"
    store.setProfiles(profiles)
    XCTAssertEqual(changes, 4)

    withExtendedLifetime(cancellable) {}
  }
}
