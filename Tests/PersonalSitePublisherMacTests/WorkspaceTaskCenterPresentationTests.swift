import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

final class WorkspaceTaskCenterPresentationTests: XCTestCase {
  func testRunningTasksAppearBeforeFailuresAndFollowTaskKindOrder() {
    let tasks = [
      WorkbenchTaskItem(id: "git", kind: .gitPush, detail: "失败", state: .failed),
      WorkbenchTaskItem(id: "image", kind: .imageProcessing, detail: "运行", state: .running),
      WorkbenchTaskItem(id: "ai", kind: .aiRequest, detail: "失败", state: .failed),
    ]

    let ordered = WorkspaceTaskCenterPresentation.ordered(tasks)

    XCTAssertEqual(ordered.map(\.id), ["image", "ai", "git"])
  }
}

@MainActor
final class WorkspaceTaskCenterNavigationTests: XCTestCase {
  func testLocateAssetResourceManagerKeepsSheetWindowIntentAndRequestOwnership() throws {
    let store = makeStore()
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let windowID = UUID()
    let presentingWindow = WorkspaceWindowSession(
      windowID: windowID,
      selectedSection: .writing,
      selectedDraftID: draftID
    )
    let otherWindow = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: draftID
    )
    let task = WorkbenchTaskItem(
      id: "asset-location",
      kind: .imageProcessing,
      detail: "图片处理完成",
      state: .completed,
      target: .assetResourceManager(profileID: store.activeProfileID)
    )

    let message = WorkspaceTaskCenterNavigation.locate(
      task, store: store, windowSession: presentingWindow
    )

    XCTAssertNil(message)
    XCTAssertEqual(presentingWindow.selectedSection, .images)
    XCTAssertEqual(presentingWindow.selectedDraftID, draftID)
    let request = try XCTUnwrap(store.imageWorkbench.assetResourceManagerNavigationRequest)
    XCTAssertEqual(request.windowID, windowID)
    store.imageWorkbench.consumeAssetResourceManagerNavigationRequest(
      request, from: otherWindow.windowID
    )
    XCTAssertEqual(
      store.imageWorkbench.assetResourceManagerNavigationRequest, request,
      "A different window must not consume the resource navigation request."
    )
    otherWindow.setKeyWindow(true) { _, _ in }
    XCTAssertEqual(otherWindow.selectedSection, .writing)

    var activatedContext: (WorkspaceSection, UUID?)?
    presentingWindow.setKeyWindow(true) { section, selectedDraftID in
      activatedContext = (section, selectedDraftID)
    }
    XCTAssertEqual(activatedContext?.0, .images)
    XCTAssertEqual(activatedContext?.1, draftID)

    store.imageWorkbench.consumeAssetResourceManagerNavigationRequest(
      request, from: presentingWindow.windowID
    )
    XCTAssertNil(store.imageWorkbench.assetResourceManagerNavigationRequest)
  }

  func testLocateValidDraftUpdatesWindowDraftIntent() throws {
    let store = makeStore()
    let originalDraftID = try XCTUnwrap(store.selectedDraft?.id)
    let targetDraftID = store.createDraftWithoutChangingSelection()
    let session = WorkspaceWindowSession(
      selectedSection: .sync,
      selectedDraftID: originalDraftID
    )
    let task = WorkbenchTaskItem(
      id: "draft-location",
      kind: .aiRequest,
      detail: "文章任务",
      state: .completed,
      target: .draft(targetDraftID)
    )

    XCTAssertNil(
      WorkspaceTaskCenterNavigation.locate(task, store: store, windowSession: session)
    )
    XCTAssertEqual(session.selectedSection, .writing)
    XCTAssertEqual(session.selectedDraftID, targetDraftID)
    XCTAssertEqual(store.selectedDraftID, targetDraftID)
  }

  func testLocateWithoutTargetOrWithMissingTargetLeavesNavigationUnchanged() throws {
    let store = makeStore()
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let session = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: draftID
    )
    let originalStoreSection = store.selectedSection
    let noTarget = WorkbenchTaskItem(
      id: "no-target",
      kind: .imageProcessing,
      detail: "没有目标",
      state: .completed
    )
    let missingTarget = WorkbenchTaskItem(
      id: "missing-target",
      kind: .imageProcessing,
      detail: "站点已删除",
      state: .completed,
      target: .assetResourceManager(profileID: UUID())
    )

    XCTAssertNotNil(
      WorkspaceTaskCenterNavigation.locate(noTarget, store: store, windowSession: session)
    )
    XCTAssertEqual(session.selectedSection, .writing)
    XCTAssertEqual(session.selectedDraftID, draftID)
    XCTAssertEqual(store.selectedSection, originalStoreSection)
    XCTAssertNil(store.imageWorkbench.assetResourceManagerNavigationRequest)

    XCTAssertNotNil(
      WorkspaceTaskCenterNavigation.locate(
        missingTarget, store: store, windowSession: session
      )
    )
    XCTAssertEqual(session.selectedSection, .writing)
    XCTAssertEqual(session.selectedDraftID, draftID)
    XCTAssertEqual(store.selectedSection, originalStoreSection)
    XCTAssertNil(store.imageWorkbench.assetResourceManagerNavigationRequest)
  }

  func testOpenSyncWorkspaceRecordsIntentForNonKeyWindowAndKeepsDraft() throws {
    let store = makeStore()
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let session = WorkspaceWindowSession(
      selectedSection: .writing,
      selectedDraftID: draftID
    )
    store.selectSection(.writing)

    WorkspaceTaskCenterNavigation.openSyncWorkspace(store: store, windowSession: session)

    XCTAssertEqual(session.selectedSection, .sync)
    XCTAssertEqual(session.selectedDraftID, draftID)
    XCTAssertEqual(store.selectedSection, .sync)
  }

  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("task-center-navigation-" + UUID().uuidString + ".json")
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }
}
