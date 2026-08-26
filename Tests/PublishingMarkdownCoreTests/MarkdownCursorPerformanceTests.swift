import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownCursorPerformanceTests: XCTestCase {
  func testSnapshotReusesDocumentIndexForSelectionChangesAndRebuildsForRevision() {
    let service = MarkdownCursorContextService()
    let source = "标题\n\n```swift\nlet value = 1\n```\n正文"
    let firstCursor = (source as NSString).range(of: "value").location
    let secondCursor = (source as NSString).range(of: "正文").location

    _ = service.snapshot(
      in: source,
      selectedRange: NSRange(location: firstCursor, length: 0),
      revision: 7
    )
    XCTAssertEqual(service.debugIndexBuildCount, 1)

    _ = service.snapshot(
      in: source,
      selectedRange: NSRange(location: secondCursor, length: 0),
      revision: 7
    )
    XCTAssertEqual(service.debugIndexBuildCount, 1)

    _ = service.snapshot(
      in: source,
      selectedRange: NSRange(location: secondCursor, length: 0),
      revision: 8
    )
    XCTAssertEqual(service.debugIndexBuildCount, 2)

    let replacement = "替换正文\n~~~yaml\nvalue: true"
    service.invalidateCache()
    let replacementSnapshot = service.snapshot(
      in: replacement,
      selectedRange: NSRange(location: (replacement as NSString).length, length: 0),
      revision: 8
    )
    XCTAssertEqual(service.debugIndexBuildCount, 3)
    XCTAssertEqual(replacementSnapshot.position?.line, 3)
    XCTAssertEqual(replacementSnapshot.fenceMatch?.marker, "~")
  }

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

  func testSingleLineInsertionUpdatesIndexIncrementally() throws {
    let service = MarkdownCursorContextService()
    let source = "首行\n正文\n```swift\nlet value = 1\n```\n尾行"
    let initialCursor = (source as NSString).range(of: "正文").upperBound
    _ = service.snapshot(
      in: source,
      selectedRange: NSRange(location: initialCursor, length: 0),
      revision: 10
    )

    let edited = (source as NSString).replacingCharacters(
      in: NSRange(location: initialCursor, length: 0),
      with: "X"
    )
    service.prepareForBodyChange()
    let actual = service.snapshot(
      in: edited,
      selectedRange: NSRange(location: initialCursor + 1, length: 0),
      revision: 11
    )

    XCTAssertEqual(service.debugIndexBuildCount, 1)
    XCTAssertEqual(service.debugIncrementalUpdateCount, 1)

    let expected = MarkdownCursorContextService().snapshot(
      in: edited,
      selectedRange: NSRange(location: initialCursor + 1, length: 0),
      revision: 11
    )
    XCTAssertEqual(actual.position, expected.position)
    XCTAssertEqual(actual.fenceMatch, expected.fenceMatch)
    XCTAssertEqual(actual.position?.line, 2)
    XCTAssertNil(actual.fenceMatch)
  }

  func testSingleCharacterDeletionInsideFenceUpdatesRangesIncrementally() throws {
    let service = MarkdownCursorContextService()
    let source = "```swift\nlet value = 1\n```"
    let initialCursor = (source as NSString).range(of: "value").upperBound
    _ = service.snapshot(
      in: source,
      selectedRange: NSRange(location: initialCursor, length: 0),
      revision: 20
    )

    let edited = (source as NSString).replacingCharacters(
      in: NSRange(location: initialCursor - 1, length: 1),
      with: ""
    )
    service.prepareForBodyChange()
    let actual = service.snapshot(
      in: edited,
      selectedRange: NSRange(location: initialCursor - 1, length: 0),
      revision: 21
    )
    let expected = MarkdownCursorContextService().snapshot(
      in: edited,
      selectedRange: NSRange(location: initialCursor - 1, length: 0),
      revision: 21
    )

    XCTAssertEqual(service.debugIndexBuildCount, 1)
    XCTAssertEqual(service.debugIncrementalUpdateCount, 1)
    XCTAssertEqual(actual.position, expected.position)
    XCTAssertEqual(actual.fenceMatch, expected.fenceMatch)
    XCTAssertEqual(actual.fenceMatch?.bodyRange, expected.fenceMatch?.bodyRange)
    XCTAssertEqual(actual.fenceMatch?.closingMarkerRange, expected.fenceMatch?.closingMarkerRange)
  }

  func testUnclosedFenceEndInsertionExtendsFenceIncrementally() throws {
    let service = MarkdownCursorContextService()
    let source = "```swift\nvalue"
    let initialCursor = (source as NSString).length
    let initial = service.snapshot(
      in: source,
      selectedRange: NSRange(location: initialCursor, length: 0),
      revision: 30
    )
    XCTAssertEqual(initial.fenceMatch?.bodyRange.length, 5)

    let edited = source + "!"
    service.prepareForBodyChange()
    let actual = service.snapshot(
      in: edited,
      selectedRange: NSRange(location: initialCursor + 1, length: 0),
      revision: 31
    )
    let expected = MarkdownCursorContextService().snapshot(
      in: edited,
      selectedRange: NSRange(location: initialCursor + 1, length: 0),
      revision: 31
    )

    XCTAssertEqual(service.debugIndexBuildCount, 1)
    XCTAssertEqual(service.debugIncrementalUpdateCount, 1)
    XCTAssertEqual(actual.fenceMatch, expected.fenceMatch)
    XCTAssertEqual(actual.fenceMatch?.bodyRange.length, 6)
    XCTAssertEqual(actual.fenceMatch?.fullRange.length, expected.fenceMatch?.fullRange.length)
  }

  func testStructuralAndFenceMarkerEditsFallBackToFullScan() {
    let source = "正文\n```swift\nlet value = 1\n```\n尾行"

    do {
      let service = MarkdownCursorContextService()
      let cursor = (source as NSString).range(of: "正文").upperBound
      _ = service.snapshot(
        in: source,
        selectedRange: NSRange(location: cursor, length: 0),
        revision: 40
      )
      let edited = (source as NSString).replacingCharacters(
        in: NSRange(location: cursor, length: 0),
        with: "\n"
      )
      service.prepareForBodyChange()
      _ = service.snapshot(
        in: edited,
        selectedRange: NSRange(location: cursor + 1, length: 0),
        revision: 41
      )
      XCTAssertEqual(service.debugIndexBuildCount, 2)
      XCTAssertEqual(service.debugIncrementalUpdateCount, 0)
    }

    do {
      let service = MarkdownCursorContextService()
      let cursor = (source as NSString).range(of: "```").upperBound
      _ = service.snapshot(
        in: source,
        selectedRange: NSRange(location: cursor, length: 0),
        revision: 50
      )
      let edited = (source as NSString).replacingCharacters(
        in: NSRange(location: cursor, length: 0),
        with: "`"
      )
      service.prepareForBodyChange()
      _ = service.snapshot(
        in: edited,
        selectedRange: NSRange(location: cursor + 1, length: 0),
        revision: 51
      )
      XCTAssertEqual(service.debugIndexBuildCount, 2)
      XCTAssertEqual(service.debugIncrementalUpdateCount, 0)
    }
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
