import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownOutlineServiceTests: XCTestCase {
  func testParsesH2AndH3HeadingsOnly() {
    let outline = MarkdownOutlineService().outline(
      in: """
      # Title

      ## Plan
      Body

      ### Detail
      More

      #### Ignored
      """
    )

    XCTAssertEqual(outline.map(\.level), [2, 3])
    XCTAssertEqual(outline.map(\.title), ["Plan", "Detail"])
  }

  func testSectionRangesJumpToHeadingStarts() throws {
    let markdown = """
    Intro

    ## First
    Alpha

    ## Second
    Beta
    """

    let outline = MarkdownOutlineService().outline(in: markdown)
    let first = try XCTUnwrap(outline.first)
    let second = try XCTUnwrap(outline.last)

    XCTAssertEqual((markdown as NSString).substring(with: first.headingRange), "## First")
    XCTAssertEqual((markdown as NSString).substring(with: second.headingRange), "## Second")
    XCTAssertTrue((markdown as NSString).substring(with: first.sectionRange).contains("Alpha"))
    XCTAssertFalse((markdown as NSString).substring(with: first.sectionRange).contains("Beta"))
  }

  func testMarksSectionsWithPublicRiskIssues() throws {
    let outline = MarkdownOutlineService().outline(
      in: """
      ## Safe
      Public content.

      ## Risky
      api_key = "abcdefghijklmnopqrstuvwxyz"
      """
    )

    let safe = try XCTUnwrap(outline.first)
    let risky = try XCTUnwrap(outline.last)

    XCTAssertTrue(safe.publicRiskSummary.isClear)
    XCTAssertEqual(risky.publicRiskSummary.errorCount, 1)
  }
}
