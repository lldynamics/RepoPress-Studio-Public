import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class MarkdownCursorPerformanceTests: XCTestCase {
  func testSnapshotReusesRevisionSelectionAndPreservesNotFoundSemantics() {
    let service = MarkdownCursorContextService()
    let source = "正文\n```swift\nlet value = 1\n```"
    let cursor = (source as NSString).range(of: "value").location
    let snapshot = service.snapshot(
      in: source,
      selectedRange: NSRange(location: cursor, length: 0),
      revision: 42
    )

    XCTAssertEqual(snapshot.revision, 42)
    XCTAssertEqual(snapshot.selectedRange, NSRange(location: cursor, length: 0))
    XCTAssertEqual(snapshot.position?.line, 3)
    XCTAssertNotNil(snapshot.fenceMatch)

    let notFound = service.snapshot(
      in: source,
      selectedRange: NSRange(location: NSNotFound, length: 0),
      revision: 43
    )
    XCTAssertNil(notFound.position)
    XCTAssertNil(notFound.fenceMatch)
  }

  func testCompletionTriggerGateAvoidsBuildingForOrdinaryCursorMovement() {
    let service = MarkdownCursorCompletionService()
    XCTAssertFalse(
      service.shouldBuildCompletion(
        in: "普通正文",
        selectedRange: NSRange(location: 2, length: 0)
      )
    )
    XCTAssertTrue(
      service.shouldBuildCompletion(
        in: "/表",
        selectedRange: NSRange(location: 2, length: 0)
      )
    )
    XCTAssertTrue(
      service.shouldBuildCompletion(
        in: "参见 [[发",
        selectedRange: NSRange(location: ("参见 [[发" as NSString).length, length: 0)
      )
    )
  }
}
