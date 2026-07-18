import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownTableEditingServiceTests: XCTestCase {
  private let service = MarkdownTableEditingService()

  func testFindsTableContextAndRejectsTextOutsideTablesAndFencedCode() throws {
    let markdown = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nEnd"
    let context = try XCTUnwrap(
      service.context(
        in: markdown,
        selectedRange: cursor(in: markdown, token: "1")
      )
    )

    XCTAssertEqual(context.rowIndex, 2)
    XCTAssertEqual(context.columnIndex, 0)
    XCTAssertFalse(context.isSeparatorRow)
    XCTAssertTrue(context.canDeleteRow)
    XCTAssertTrue(context.canDeleteColumn)
    XCTAssertNil(
      service.context(
        in: markdown,
        selectedRange: cursor(in: markdown, token: "Intro")
      )
    )

    let tableWithTrailingNewline = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
    XCTAssertNil(
      service.context(
        in: tableWithTrailingNewline,
        selectedRange: NSRange(
          location: (tableWithTrailingNewline as NSString).length,
          length: 0
        )
      )
    )

    let fenced = "```\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```"
    XCTAssertNil(
      service.context(
        in: fenced,
        selectedRange: cursor(in: fenced, token: "1")
      )
    )
  }

  func testTableParserIgnoresEscapedAndCodeSpanPipes() throws {
    let markdown = "| A \\| literal | `B|C` |\n| --- | --- |\n| x | y |"
    let context = try XCTUnwrap(
      service.context(
        in: markdown,
        selectedRange: cursor(in: markdown, token: "y")
      )
    )

    XCTAssertEqual(context.columnIndex, 1)
  }

  func testTabNavigatesEditableCellsAndSkipsSeparatorRow() throws {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |"

    let headerNext = try edit(
      markdown,
      range: cursor(in: markdown, token: "A"),
      command: .navigateForward
    )
    XCTAssertEqual(selectedText(afterApplying: headerNext, to: markdown), "B")

    let firstDataCell = try edit(
      markdown,
      range: cursor(in: markdown, token: "B"),
      command: .navigateForward
    )
    XCTAssertEqual(selectedText(afterApplying: firstDataCell, to: markdown), "1")

    let previousHeaderCell = try edit(
      markdown,
      range: cursor(in: markdown, token: "1"),
      command: .navigateBackward
    )
    XCTAssertEqual(selectedText(afterApplying: previousHeaderCell, to: markdown), "B")
  }

  func testTabFromLastCellAppendsBlankRowAndMovesToItsFirstCell() throws {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let edit = try self.edit(
      markdown,
      range: cursor(in: markdown, token: "2"),
      command: .navigateForward
    )
    let updated = applying(edit, to: markdown)

    XCTAssertEqual(
      updated,
      "| A   | B   |\n| --- | --- |\n| 1   | 2   |\n|     |     |"
    )
    XCTAssertEqual(edit.selectedRange.length, 0)
    XCTAssertEqual((updated as NSString).substring(with: edit.selectedRange), "")
  }

  func testTabMaterializesMissingTrailingCellInRaggedRow() throws {
    let markdown = "| A | B |\n| --- | --- |\n| 1 |"
    let edit = try self.edit(
      markdown,
      range: cursor(in: markdown, token: "1"),
      command: .navigateForward
    )
    let updated = applying(edit, to: markdown)

    XCTAssertEqual(
      updated,
      "| A   | B   |\n| --- | --- |\n| 1   |     |"
    )
    XCTAssertEqual(edit.selectedRange.length, 0)
  }

  func testFormatsTableAndPreservesAlignmentMarkers() throws {
    let markdown = "|Name|Score|\n|:---|---:|\n|Ada|9|"
    let edit = try self.edit(
      markdown,
      range: cursor(in: markdown, token: "Ada", offset: 2),
      command: .format
    )
    let updated = applying(edit, to: markdown)

    XCTAssertEqual(
      updated,
      "| Name | Score |\n| :--- | ----: |\n| Ada  | 9     |"
    )
    XCTAssertEqual(edit.selectedRange.length, 0)
    XCTAssertEqual((updated as NSString).substring(to: edit.selectedRange.location).suffix(2), "Ad")
  }

  func testInsertsAndDeletesRowsWithoutAllowingHeaderDeletion() throws {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let dataCursor = cursor(in: markdown, token: "1")

    let insertedAbove = try edit(markdown, range: dataCursor, command: .insertRowAbove)
    XCTAssertEqual(
      applying(insertedAbove, to: markdown),
      "| A   | B   |\n| --- | --- |\n|     |     |\n| 1   | 2   |"
    )

    let insertedBelow = try edit(markdown, range: dataCursor, command: .insertRowBelow)
    XCTAssertEqual(
      applying(insertedBelow, to: markdown),
      "| A   | B   |\n| --- | --- |\n| 1   | 2   |\n|     |     |"
    )

    let deleted = try edit(markdown, range: dataCursor, command: .deleteRow)
    XCTAssertEqual(applying(deleted, to: markdown), "| A   | B   |\n| --- | --- |")
    XCTAssertNil(
      service.edit(
        in: markdown,
        selectedRange: cursor(in: markdown, token: "A"),
        command: .deleteRow
      )
    )
  }

  func testInsertsAndDeletesColumnsAndKeepsAtLeastOneColumn() throws {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let secondColumnCursor = cursor(in: markdown, token: "B")

    let inserted = try edit(markdown, range: secondColumnCursor, command: .insertColumnBefore)
    XCTAssertEqual(
      applying(inserted, to: markdown),
      "| A   |     | B   |\n| --- | --- | --- |\n| 1   |     | 2   |"
    )

    let deleted = try edit(markdown, range: secondColumnCursor, command: .deleteColumn)
    XCTAssertEqual(
      applying(deleted, to: markdown),
      "| A   |\n| --- |\n| 1   |"
    )

    let oneColumn = "| A |\n| --- |\n| 1 |"
    XCTAssertNil(
      service.edit(
        in: oneColumn,
        selectedRange: cursor(in: oneColumn, token: "A"),
        command: .deleteColumn
      )
    )
  }

  private func edit(
    _ markdown: String,
    range: NSRange,
    command: MarkdownTableEditingCommand
  ) throws -> MarkdownSmartEdit {
    try XCTUnwrap(
      service.edit(in: markdown, selectedRange: range, command: command)
    )
  }

  private func cursor(in markdown: String, token: String, offset: Int = 0) -> NSRange {
    let tokenRange = (markdown as NSString).range(of: token)
    return NSRange(location: tokenRange.location + offset, length: 0)
  }

  private func applying(_ edit: MarkdownSmartEdit, to markdown: String) -> String {
    (markdown as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
  }

  private func selectedText(
    afterApplying edit: MarkdownSmartEdit,
    to markdown: String
  ) -> String {
    let updated = applying(edit, to: markdown)
    return (updated as NSString).substring(with: edit.selectedRange)
  }
}
