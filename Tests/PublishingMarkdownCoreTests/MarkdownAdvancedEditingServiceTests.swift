import XCTest

@testable import PublishingMarkdownCore

final class MarkdownAdvancedEditingServiceTests: XCTestCase {
  private let service = MarkdownAdvancedEditingService()

  func testInlineFormattingWrapsAndTogglesEverySupportedStyle() throws {
    let cases: [(MarkdownAdvancedFormattingCommand, String)] = [
      (.bold, "**"),
      (.italic, "*"),
      (.strikethrough, "~~"),
      (.inlineCode, "`"),
    ]

    for (command, marker) in cases {
      let markdown = "write clearly"
      let range = (markdown as NSString).range(of: "clearly")
      let wrapped = try formattingEdit(markdown, range: range, command: command)
      let formatted = applying(wrapped, to: markdown)

      XCTAssertEqual(formatted, "write \(marker)clearly\(marker)")
      XCTAssertEqual(
        wrapped.selectedRange,
        NSRange(location: 6 + marker.utf16.count, length: 7)
      )

      let toggled = try formattingEdit(
        formatted,
        range: wrapped.selectedRange,
        command: command
      )
      XCTAssertEqual(applying(toggled, to: formatted), markdown)
      XCTAssertEqual(toggled.selectedRange, range)
    }
  }

  func testInlineFormattingUsesSafeMarkersForBackticksInsideSelection() throws {
    let markdown = "Call a`b now"
    let range = (markdown as NSString).range(of: "a`b")
    let edit = try formattingEdit(markdown, range: range, command: .inlineCode)

    XCTAssertEqual(applying(edit, to: markdown), "Call ``a`b`` now")
    XCTAssertEqual(edit.replacement, "``a`b``")
  }

  func testMultilineInlineFormattingWrapsEachNonemptyLineAndTogglesSafely() throws {
    let markdown = "One\n\nTwo\nEnd"
    let selectedText = "One\n\nTwo"
    let selection = NSRange(location: 0, length: selectedText.utf16.count)
    let wrapped = try formattingEdit(markdown, range: selection, command: .bold)
    let formatted = applying(wrapped, to: markdown)

    XCTAssertEqual(formatted, "**One**\n\n**Two**\nEnd")
    XCTAssertEqual(
      wrapped.selectedRange,
      NSRange(location: 0, length: "**One**\n\n**Two**".utf16.count)
    )

    let toggled = try formattingEdit(
      formatted,
      range: wrapped.selectedRange,
      command: .bold
    )
    XCTAssertEqual(applying(toggled, to: formatted), markdown)
  }

  func testBlockFormattingConvertsExistingMarkersAndToggles() throws {
    let markdown = "- One\n- [x] Two\n> Three"
    let selection = NSRange(location: 0, length: markdown.utf16.count)
    let tasks = try formattingEdit(markdown, range: selection, command: .taskList)
    let taskMarkdown = applying(tasks, to: markdown)

    XCTAssertEqual(taskMarkdown, "- [ ] One\n- [ ] Two\n- [ ] Three")

    let removed = try formattingEdit(
      taskMarkdown,
      range: NSRange(location: 0, length: taskMarkdown.utf16.count),
      command: .taskList
    )
    XCTAssertEqual(applying(removed, to: taskMarkdown), "One\nTwo\nThree")
  }

  func testOrderedListNumbersNonemptyLinesAndPreservesBlankLines() throws {
    let markdown = "First\n\nSecond"
    let selection = NSRange(location: 0, length: markdown.utf16.count)
    let edit = try formattingEdit(markdown, range: selection, command: .orderedList)

    XCTAssertEqual(applying(edit, to: markdown), "1. First\n\n2. Second")
  }

  func testRemoveFormattingRemovesBlockAndInlineMarkersFromCurrentLine() throws {
    let markdown = "Before\n> **Bold** and ~~gone~~ with `code`\nAfter"
    let cursor = (markdown as NSString).range(of: "gone").location
    let edit = try formattingEdit(
      markdown,
      range: NSRange(location: cursor, length: 0),
      command: .removeFormatting
    )

    XCTAssertEqual(
      applying(edit, to: markdown),
      "Before\nBold and gone with code\nAfter"
    )
    XCTAssertEqual(edit.selectedRange.length, "Bold and gone with code".utf16.count)
  }

  func testFormattingDoesNotModifyFencedCode() {
    let markdown = "```\ncode\n```"
    let cursor = (markdown as NSString).range(of: "code").location

    XCTAssertNil(
      service.formattingEdit(
        in: markdown,
        selectedRange: NSRange(location: cursor, length: 0),
        command: .bold
      )
    )
  }

  func testMoveCurrentLineUpAndDownKeepsCursorColumn() throws {
    let markdown = "One\nTwo\nThree"
    let cursor = (markdown as NSString).range(of: "wo").location + 1
    let movedUp = try lineEdit(
      markdown,
      range: NSRange(location: cursor, length: 0),
      command: .moveUp
    )
    let movedUpMarkdown = applying(movedUp, to: markdown)

    XCTAssertEqual(movedUpMarkdown, "Two\nOne\nThree")
    XCTAssertEqual(movedUp.selectedRange, NSRange(location: 2, length: 0))

    let movedDown = try lineEdit(
      movedUpMarkdown,
      range: movedUp.selectedRange,
      command: .moveDown
    )
    XCTAssertEqual(applying(movedDown, to: movedUpMarkdown), markdown)
    XCTAssertEqual(movedDown.selectedRange, NSRange(location: cursor, length: 0))
  }

  func testMoveMultipleLinesDownPreservesDocumentWithoutTrailingNewline() throws {
    let markdown = "One\nTwo\nThree\nFour"
    let selection = (markdown as NSString).range(of: "Two\nThree")
    let edit = try lineEdit(markdown, range: selection, command: .moveDown)

    XCTAssertEqual(applying(edit, to: markdown), "One\nFour\nTwo\nThree")
    XCTAssertEqual(
      edit.selectedRange,
      NSRange(location: "One\nFour\n".utf16.count, length: "Two\nThree".utf16.count)
    )
  }

  func testMoveAtDocumentBoundaryReturnsNil() {
    XCTAssertNil(
      service.lineEdit(
        in: "One\nTwo",
        selectedRange: NSRange(location: 0, length: 0),
        command: .moveUp
      )
    )
    XCTAssertNil(
      service.lineEdit(
        in: "One\nTwo",
        selectedRange: NSRange(location: 5, length: 0),
        command: .moveDown
      )
    )
  }

  func testDuplicateLineAboveAndBelowHandlesMissingTrailingNewline() throws {
    let markdown = "One\nTwo"
    let cursor = NSRange(location: markdown.utf16.count, length: 0)

    let above = try lineEdit(markdown, range: cursor, command: .duplicateAbove)
    XCTAssertEqual(applying(above, to: markdown), "One\nTwo\nTwo")
    XCTAssertEqual(above.selectedRange, NSRange(location: 7, length: 0))

    let below = try lineEdit(markdown, range: cursor, command: .duplicateBelow)
    XCTAssertEqual(applying(below, to: markdown), "One\nTwo\nTwo")
    XCTAssertEqual(below.selectedRange, NSRange(location: 11, length: 0))
  }

  func testTaskCompletionChecksMixedSelectionThenUnchecksAll() throws {
    let markdown = "- [ ] One\n- [x] Two\nPlain"
    let selection = NSRange(location: 0, length: markdown.utf16.count)
    let checked = try lineEdit(
      markdown,
      range: selection,
      command: .toggleTaskCompletion
    )
    let checkedMarkdown = applying(checked, to: markdown)

    XCTAssertEqual(checkedMarkdown, "- [x] One\n- [x] Two\nPlain")

    let unchecked = try lineEdit(
      checkedMarkdown,
      range: NSRange(location: 0, length: checkedMarkdown.utf16.count),
      command: .toggleTaskCompletion
    )
    XCTAssertEqual(
      applying(unchecked, to: checkedMarkdown),
      "- [ ] One\n- [ ] Two\nPlain"
    )
  }

  func testDeleteLineRemovesCurrentLineAndAdjustsCursor() throws {
    let markdown = "First line\nSecond line\nThird line"
    let cursor = (markdown as NSString).range(of: "Second").location
    let edit = try lineEdit(
      markdown,
      range: NSRange(location: cursor, length: 0),
      command: .deleteLine
    )
    let result = applying(edit, to: markdown)
    XCTAssertEqual(result, "First line\nThird line")
  }

  func testDeleteLastLineWithoutTrailingNewline() throws {
    let markdown = "First line\nSecond line"
    let cursor = (markdown as NSString).range(of: "Second").location
    let edit = try lineEdit(
      markdown,
      range: NSRange(location: cursor, length: 0),
      command: .deleteLine
    )
    let result = applying(edit, to: markdown)
    XCTAssertEqual(result, "First line")
  }

  func testToggleCommentCommentsAndUncommentsLines() throws {
    let markdown = "First line\nSecond line"
    let edit = try lineEdit(
      markdown,
      range: NSRange(location: 0, length: markdown.utf16.count),
      command: .toggleComment
    )
    let commented = applying(edit, to: markdown)
    XCTAssertEqual(commented, "<!-- First line -->\n<!-- Second line -->")

    let uncommentEdit = try lineEdit(
      commented,
      range: NSRange(location: 0, length: commented.utf16.count),
      command: .toggleComment
    )
    let uncommented = applying(uncommentEdit, to: commented)
    XCTAssertEqual(uncommented, "First line\nSecond line")
  }

  func testBracketPairingWrapsSelectionAndSupportsChineseSymbols() throws {
    let markdown = "选择文字"
    let selection = (markdown as NSString).range(of: "文字")
    let edit = try pairingEdit(markdown, range: selection, typedText: "《")

    XCTAssertEqual(applying(edit, to: markdown), "选择《文字》")
    XCTAssertEqual(
      edit.selectedRange,
      NSRange(location: selection.location + 1, length: selection.length)
    )
  }

  func testPairingAtCursorPlacesCursorInsideAndSkipsExistingClosingSymbol() throws {
    let inserted = try pairingEdit(
      "call",
      range: NSRange(location: 4, length: 0),
      typedText: "("
    )
    let markdown = applying(inserted, to: "call")
    XCTAssertEqual(markdown, "call()")
    XCTAssertEqual(inserted.selectedRange, NSRange(location: 5, length: 0))

    let skipped = try pairingEdit(
      markdown,
      range: inserted.selectedRange,
      typedText: ")"
    )
    XCTAssertEqual(applying(skipped, to: markdown), markdown)
    XCTAssertEqual(skipped.selectedRange, NSRange(location: 6, length: 0))
  }

  func testQuoteAndBacktickPairingWrapSelections() throws {
    let quote = try pairingEdit(
      "word",
      range: NSRange(location: 0, length: 4),
      typedText: "\""
    )
    XCTAssertEqual(applying(quote, to: "word"), "\"word\"")

    let backtick = try pairingEdit(
      "value",
      range: NSRange(location: 0, length: 5),
      typedText: "`"
    )
    XCTAssertEqual(applying(backtick, to: "value"), "`value`")
  }

  func testFencePairingCreatesEmptyBlockAndWrapsSelection() throws {
    let empty = try pairingEdit(
      "",
      range: NSRange(location: 0, length: 0),
      typedText: "```"
    )
    XCTAssertEqual(applying(empty, to: ""), "```\n\n```")
    XCTAssertEqual(empty.selectedRange, NSRange(location: 4, length: 0))

    let markdown = "let value = 1"
    let wrapped = try pairingEdit(
      markdown,
      range: NSRange(location: 0, length: markdown.utf16.count),
      typedText: "```"
    )
    XCTAssertEqual(applying(wrapped, to: markdown), "```\nlet value = 1\n```")
    XCTAssertEqual(
      wrapped.selectedRange,
      NSRange(location: 4, length: markdown.utf16.count)
    )
  }

  func testInvalidRangesAndUnsupportedPairingReturnNil() {
    XCTAssertNil(
      service.formattingEdit(
        in: "Text",
        selectedRange: NSRange(location: -1, length: 0),
        command: .bold
      )
    )
    XCTAssertNil(
      service.pairingEdit(
        in: "Text",
        selectedRange: NSRange(location: 0, length: 0),
        typedText: "/"
      )
    )
  }

  private func formattingEdit(
    _ markdown: String,
    range: NSRange,
    command: MarkdownAdvancedFormattingCommand
  ) throws -> MarkdownSmartEdit {
    try XCTUnwrap(
      service.formattingEdit(
        in: markdown,
        selectedRange: range,
        command: command
      )
    )
  }

  private func lineEdit(
    _ markdown: String,
    range: NSRange,
    command: MarkdownLineEditingCommand
  ) throws -> MarkdownSmartEdit {
    try XCTUnwrap(
      service.lineEdit(
        in: markdown,
        selectedRange: range,
        command: command
      )
    )
  }

  private func pairingEdit(
    _ markdown: String,
    range: NSRange,
    typedText: String
  ) throws -> MarkdownSmartEdit {
    try XCTUnwrap(
      service.pairingEdit(
        in: markdown,
        selectedRange: range,
        typedText: typedText
      )
    )
  }

  private func applying(
    _ edit: MarkdownSmartEdit,
    to markdown: String
  ) -> String {
    (markdown as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
  }
}
