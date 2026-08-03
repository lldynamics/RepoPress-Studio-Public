import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchTaskCenterModelsTests: XCTestCase {
  func testTaskKindCoversTheSixUnifiedTaskSources() {
    XCTAssertEqual(
      WorkbenchTaskKind.allCases,
      [.aiRequest, .knowledgeImport, .imageProcessing, .siteScan, .gitPush, .deployment]
    )
  }

  func testProgressIsClampedToDisplayableRange() {
    let low = WorkbenchTaskItem(
      id: "low",
      kind: .imageProcessing,
      detail: "低于范围",
      progress: -0.4,
      state: .running
    )
    let high = WorkbenchTaskItem(
      id: "high",
      kind: .imageProcessing,
      detail: "高于范围",
      progress: 1.4,
      state: .running
    )

    XCTAssertEqual(low.progress, 0)
    XCTAssertEqual(high.progress, 1)
  }
}
