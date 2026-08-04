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

  func testParentSectionRangeIncludesChildHeadingsButStopsAtNextParent() throws {
    let markdown = """
    ## Parent
    Intro

    ### Child
    Details

    ## Next
    Ending
    """

    let outline = MarkdownOutlineService().outline(in: markdown)
    let parent = try XCTUnwrap(outline.first)
    let parentMarkdown = (markdown as NSString).substring(with: parent.sectionRange)

    XCTAssertTrue(parentMarkdown.contains("### Child"))
    XCTAssertTrue(parentMarkdown.contains("Details"))
    XCTAssertFalse(parentMarkdown.contains("## Next"))
  }

  func testMovesParentSectionWithItsChildrenAndKeepsIntroInPlace() throws {
    let markdown = """
    Intro

    ## Alpha
    A

    ### Alpha Child
    A1

    ## Beta
    B
    """
    let service = MarkdownOutlineService()
    let alpha = try XCTUnwrap(service.outline(in: markdown).first)
    let edit = try XCTUnwrap(
      service.moveSectionEdit(in: markdown, item: alpha, direction: .down)
    )

    let updated = applying(edit, to: markdown)

    XCTAssertTrue(updated.hasPrefix("Intro\n\n## Beta\nB\n\n## Alpha"))
    XCTAssertTrue(updated.contains("### Alpha Child\nA1"))
    XCTAssertLessThan(
      try XCTUnwrap(updated.range(of: "## Beta")?.lowerBound),
      try XCTUnwrap(updated.range(of: "## Alpha")?.lowerBound)
    )
  }

  func testMovesChildOnlyWithinItsParentSection() throws {
    let markdown = """
    ## Parent

    ### First
    One

    ### Second
    Two

    ## Other Parent

    ### Other Child
    Three
    """
    let service = MarkdownOutlineService()
    let outline = service.outline(in: markdown)
    let first = try XCTUnwrap(outline.first { $0.title == "First" })
    let second = try XCTUnwrap(outline.first { $0.title == "Second" })

    XCTAssertTrue(service.canMoveSection(first, direction: .down, in: markdown))
    XCTAssertFalse(service.canMoveSection(second, direction: .down, in: markdown))

    let edit = try XCTUnwrap(
      service.moveSectionEdit(in: markdown, item: first, direction: .down)
    )
    let updated = applying(edit, to: markdown)

    XCTAssertLessThan(
      try XCTUnwrap(updated.range(of: "### Second")?.lowerBound),
      try XCTUnwrap(updated.range(of: "### First")?.lowerBound)
    )
    XCTAssertLessThan(
      try XCTUnwrap(updated.range(of: "### First")?.lowerBound),
      try XCTUnwrap(updated.range(of: "## Other Parent")?.lowerBound)
    )
  }

  func testDuplicatesAndDeletesWholeParentSection() throws {
    let markdown = """
    ## Parent
    Body

    ### Child
    Details

    ## Next
    Ending
    """
    let service = MarkdownOutlineService()
    let parent = try XCTUnwrap(service.outline(in: markdown).first)

    let duplicated = applying(
      try XCTUnwrap(service.duplicateSectionEdit(in: markdown, item: parent)),
      to: markdown
    )
    XCTAssertEqual(duplicated.components(separatedBy: "## Parent").count - 1, 2)
    XCTAssertEqual(duplicated.components(separatedBy: "### Child").count - 1, 2)

    let deleted = applying(
      try XCTUnwrap(service.deleteSectionEdit(in: markdown, item: parent)),
      to: markdown
    )
    XCTAssertFalse(deleted.contains("## Parent"))
    XCTAssertFalse(deleted.contains("### Child"))
    XCTAssertTrue(deleted.contains("## Next\nEnding"))
  }

  func testBuildsDeterministicAnchorLinksIncludingDuplicateHeadings() throws {
    let markdown = """
    ## Hello, *World*!
    First

    ## Hello, *World*!
    Second

    ## Hello World-1
    Reserved suffix

    ## Hello, *World*!
    Third duplicate

    ## 中文 标题
    Third

    ## [Docs](https://example.com)
    Fourth
    """
    let service = MarkdownOutlineService()
    let outline = service.outline(in: markdown)

    XCTAssertEqual(service.anchorLink(for: outline[0], in: markdown), "#hello-world")
    XCTAssertEqual(service.anchorLink(for: outline[1], in: markdown), "#hello-world-1")
    XCTAssertEqual(service.anchorLink(for: outline[2], in: markdown), "#hello-world-1-1")
    XCTAssertEqual(service.anchorLink(for: outline[3], in: markdown), "#hello-world-2")
    XCTAssertEqual(service.anchorLink(for: outline[4], in: markdown), "#中文-标题")
    XCTAssertEqual(service.anchorLink(for: outline[5], in: markdown), "#docs")
  }

  private func applying(_ edit: MarkdownSmartEdit, to markdown: String) -> String {
    (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
  }
}
