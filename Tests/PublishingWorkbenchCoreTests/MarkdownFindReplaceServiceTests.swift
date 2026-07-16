import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownFindReplaceServiceTests: XCTestCase {
  func testFindNextWrapsToBeginning() throws {
    let service = MarkdownFindReplaceService()
    let result = try XCTUnwrap(
      service.findNext(
        in: "alpha beta alpha",
        query: "alpha",
        selectedRange: NSRange(location: 12, length: 5)
      )
    )

    XCTAssertEqual(result.range, NSRange(location: 0, length: 5))
    XCTAssertTrue(result.didWrap)
  }

  func testReplaceCurrentSelectionWhenItMatchesQuery() {
    let service = MarkdownFindReplaceService()
    let mutation = service.replaceCurrentOrNext(
      in: "title draft body",
      query: "draft",
      replacement: "published",
      selectedRange: NSRange(location: 6, length: 5)
    )

    XCTAssertEqual(mutation.text, "title published body")
    XCTAssertEqual(mutation.selectedRange, NSRange(location: 6, length: 9))
    XCTAssertEqual(mutation.replacementCount, 1)
  }

  func testReplaceFindsNextWhenSelectionDoesNotMatch() {
    let service = MarkdownFindReplaceService()
    let mutation = service.replaceCurrentOrNext(
      in: "first TODO second TODO",
      query: "TODO",
      replacement: "done",
      selectedRange: NSRange(location: 0, length: 5)
    )

    XCTAssertEqual(mutation.text, "first done second TODO")
    XCTAssertEqual(mutation.selectedRange, NSRange(location: 6, length: 4))
    XCTAssertEqual(mutation.replacementCount, 1)
  }

  func testReplaceAllCanBeCaseSensitive() {
    let service = MarkdownFindReplaceService()
    let mutation = service.replaceAll(
      in: "SEO seo Seo",
      query: "seo",
      replacement: "search",
      caseSensitive: true
    )

    XCTAssertEqual(mutation.text, "SEO search Seo")
    XCTAssertEqual(mutation.replacementCount, 1)
  }

  func testFindReportsCurrentMatchAndTotalInBothDirections() throws {
    let service = MarkdownFindReplaceService()
    let next = try XCTUnwrap(
      service.find(
        in: "one two one",
        query: "one",
        selectedRange: NSRange(location: 0, length: 3),
        direction: .next
      )
    )
    XCTAssertEqual(next.range, NSRange(location: 8, length: 3))
    XCTAssertEqual(next.currentNumber, 2)
    XCTAssertEqual(next.total, 2)
    XCTAssertFalse(next.didWrap)

    let previous = try XCTUnwrap(
      service.find(
        in: "one two one",
        query: "one",
        selectedRange: NSRange(location: 0, length: 3),
        direction: .previous
      )
    )
    XCTAssertEqual(previous.range, NSRange(location: 8, length: 3))
    XCTAssertEqual(previous.currentNumber, 2)
    XCTAssertTrue(previous.didWrap)
  }

  func testWholeWordDoesNotMatchInsideAnotherWord() throws {
    let service = MarkdownFindReplaceService()
    let ranges = try service.matches(
      in: "cat scatter cat_1 cat",
      query: "cat",
      options: MarkdownFindOptions(wholeWord: true)
    )

    XCTAssertEqual(ranges, [
      NSRange(location: 0, length: 3),
      NSRange(location: 18, length: 3),
    ])
  }

  func testRegularExpressionCanReplaceCaptureGroups() throws {
    let service = MarkdownFindReplaceService()
    let mutation = try service.replaceAll(
      in: "2025-07 2026-08",
      query: #"(\d{4})-(\d{2})"#,
      replacement: "$2/$1",
      options: MarkdownFindOptions(usesRegularExpression: true)
    )

    XCTAssertEqual(mutation.text, "07/2025 08/2026")
    XCTAssertEqual(mutation.replacementCount, 2)
    XCTAssertEqual(
      mutation.edit,
      MarkdownSmartEdit(
        replacedRange: NSRange(location: 0, length: 15),
        replacement: "07/2025 08/2026",
        selectedRange: NSRange(location: 0, length: 0)
      )
    )
  }

  func testInvalidRegularExpressionReturnsSpecificError() {
    let service = MarkdownFindReplaceService()

    XCTAssertThrowsError(
      try service.matches(
        in: "content",
        query: "(",
        options: MarkdownFindOptions(usesRegularExpression: true)
      )
    ) { error in
      guard case MarkdownFindReplaceError.invalidRegularExpression = error else {
        return XCTFail("Expected invalid regular expression error, got \(error)")
      }
    }
  }

  func testPositionIsZeroCurrentUntilAMatchIsSelected() throws {
    let service = MarkdownFindReplaceService()
    let position = try service.position(
      in: "draft draft",
      query: "draft",
      selectedRange: NSRange(location: 0, length: 0)
    )

    XCTAssertNil(position.currentNumber)
    XCTAssertEqual(position.total, 2)
  }
}
