import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAutomationSettingsFeatureFacadeTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("automation-settings-facade-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
  }

  func testPublishesOnlyDistinctAutomationSettingsAndExposesCurrentValues() {
    let store = makeStore()
    let facade = WorkbenchAutomationSettingsFeatureFacade(store: store)
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setAIChatMessage("无关的 AI 状态")
    store.siteMaintenanceStore.setRefreshing(true)
    store.setSelectedSection(.rss)
    XCTAssertEqual(changes, 0)

    let repositorySettings = RepositoryAutoSyncSettings(
      isEnabled: true,
      intervalMinutes: 30,
      fetchBeforeScan: false,
      autoImportRemoteArticles: true
    )
    facade.updateRepositoryAutoSyncSettings(repositorySettings)

    XCTAssertEqual(changes, 1)
    XCTAssertEqual(facade.repositoryAutoSyncSettings, repositorySettings)

    let deploymentSettings = DeploymentPollingSettings(isEnabled: true, intervalMinutes: 15)
    facade.updateDeploymentPollingSettings(deploymentSettings)

    XCTAssertEqual(changes, 2)
    XCTAssertEqual(facade.deploymentPollingSettings, deploymentSettings)

    facade.updateRepositoryAutoSyncSettings(repositorySettings)
    facade.updateDeploymentPollingSettings(deploymentSettings)
    XCTAssertEqual(changes, 2)

    withExtendedLifetime(cancellable) {}
  }
}
