import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class UIOptimizationTaskPresentationTests: XCTestCase {
  private func makeIsolatedStore() -> WorkbenchStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "UIOptimizationTaskPresentation-\(UUID().uuidString)", isDirectory: true)
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    )
  }

  func testAssetResourceOperationAppearsInTaskCenterAndLocatesImagesForItsProfile() throws {
    let store = makeIsolatedStore()
    let profileID = store.activeProfileID
    let operationID = try XCTUnwrap(
      store.imageWorkbench.beginAssetResourceOperation(
        for: profileID,
        operationTitle: "清理孤立资源",
        loadingDetail: "正在校验并移入废纸篓…"
      )
    )

    let runningTask = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first {
        $0.id == "asset-resource-\(profileID.uuidString)"
      }
    )
    XCTAssertEqual(runningTask.state, .running)
    XCTAssertEqual(runningTask.title, "清理孤立资源")
    XCTAssertEqual(runningTask.target, .assetResourceManager(profileID: profileID))

    store.imageWorkbench.finishAssetResourceOperation(
      operationID,
      for: profileID,
      presentation: .partialSuccess(detail: "1 个资源需复核。")
    )
    let completedTask = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.id == runningTask.id }
    )
    XCTAssertEqual(completedTask.state, .needsAttention)
    XCTAssertNil(store.activityStatus.locateTask(completedTask))
    XCTAssertEqual(store.activeProfileID, profileID)
    XCTAssertEqual(store.selectedSection, .images)
    XCTAssertEqual(
      store.imageWorkbench.assetResourceManagerNavigationRequest?.profileID,
      profileID
    )
  }

  func testResourceTaskForAnotherProfileRemainsVisibleAndLocatesItsOriginalManager() throws {
    let store = makeIsolatedStore()
    let originalProfileID = store.activeProfileID
    let resourceProfile = store.createProfile(named: "资源站点")
    store.selectProfile(originalProfileID)
    let operationID = try XCTUnwrap(
      store.imageWorkbench.beginAssetResourceOperation(
        for: resourceProfile.id,
        operationTitle: "图片瘦身（2）",
        loadingDetail: "正在校验并生成图片优化结果…"
      )
    )

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first {
        $0.id == "asset-resource-\(resourceProfile.id.uuidString)"
      }
    )
    XCTAssertEqual(store.activeProfileID, originalProfileID)
    XCTAssertEqual(task.state, .running)
    XCTAssertEqual(task.target, .assetResourceManager(profileID: resourceProfile.id))

    XCTAssertNil(store.activityStatus.locateTask(task))
    XCTAssertEqual(store.activeProfileID, resourceProfile.id)
    XCTAssertEqual(store.selectedSection, .images)
    XCTAssertEqual(
      store.imageWorkbench.assetResourceManagerNavigationRequest?.profileID,
      resourceProfile.id
    )

    store.imageWorkbench.finishAssetResourceOperation(
      operationID,
      for: resourceProfile.id,
      presentation: .success(detail: "完成")
    )
  }

  func testFailedTaskUsesFailureReasonOnceForPrimaryPresentation() {
    let task = WorkbenchTaskItem(
      id: "failed-resource-task",
      kind: .imageProcessing,
      detail: "图片处理失败：/private/site/images/a.png 无法写入",
      state: .failed,
      failureReason: "/private/site/images/a.png 无法写入"
    )

    XCTAssertEqual(task.primaryPresentationDetail, "/private/site/images/a.png 无法写入")
    XCTAssertTrue(task.diagnosticText.contains(task.detail))
    XCTAssertTrue(task.diagnosticText.contains(task.failureReason ?? ""))
  }

  func testImageWorkspaceTargetSurvivesTaskSnapshotCoding() throws {
    let profileID = UUID()
    let original = WorkbenchTaskItem(
      id: "image-processing",
      kind: .imageProcessing,
      detail: "正在处理图片…",
      state: .running,
      target: .siteProfilePage(profileID: profileID, section: .images)
    )

    let decoded = try JSONDecoder().decode(
      WorkbenchTaskItem.self,
      from: JSONEncoder().encode(original)
    )
    XCTAssertEqual(decoded.target, .siteProfilePage(profileID: profileID, section: .images))
  }
}
