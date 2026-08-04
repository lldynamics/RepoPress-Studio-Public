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
