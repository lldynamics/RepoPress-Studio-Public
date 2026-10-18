import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PublishChecklistPresentationTests: XCTestCase {
  func testInspectorTabsShareOneResizableWidthRange() {
    XCTAssertEqual(WorkbenchLayoutMode.inspectorMinimumWidth, 280)
    XCTAssertEqual(WorkbenchLayoutMode.inspectorIdealWidth, 320)
    XCTAssertEqual(WorkbenchLayoutMode.inspectorMaximumWidth, 560)
    XCTAssertLessThan(
      WorkbenchLayoutMode.inspectorMinimumWidth, WorkbenchLayoutMode.inspectorMaximumWidth,
      "Users must be able to drag the Inspector narrower or wider."
    )
  }

  func testPublishFeedbackPreservesSeverityAndProvidesAccessiblePresentation() {
    let expectations: [(PublishActionMessageStatus, String, String)] = [
      (.information, "信息", "info.circle.fill"),
      (.success, "成功", "checkmark.circle.fill"),
      (.warning, "警告", "exclamationmark.triangle.fill"),
      (.failure, "失败", "xmark.octagon.fill"),
    ]

    for (status, title, systemImage) in expectations {
      XCTAssertEqual(status.publishDrawerTitle, title)
      XCTAssertEqual(status.publishDrawerSystemImage, systemImage)
    }
  }
}
