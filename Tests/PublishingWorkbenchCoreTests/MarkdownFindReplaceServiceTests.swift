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
}
