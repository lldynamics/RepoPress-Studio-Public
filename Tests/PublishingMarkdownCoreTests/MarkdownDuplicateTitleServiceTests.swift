import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownDuplicateTitleServiceTests: XCTestCase {
  func testRemovesOnlyFirstPlainTitleAndPreservesAdjacentParagraphs() throws {
    for (body, expected) in [
      ("发布流程\n连续正文\n第三行\n", "连续正文\n第三行\n"),
      ("发布流程\n\n正文\n\n", "\n正文\n\n"),
      ("\n \n发布流程\n正文", "\n \n正文"),
      ("发布流程", ""),
      ("发布流程\n发布流程\n正文", "发布流程\n正文"),
    ] {
      XCTAssertEqual(try removingTitle("发布流程", from: body), expected)
    }
  }

  func testDetectsOnlyATXLevelOneAndHandlesOptionalClosingHashes() throws {
    for body in ["# 发布流程\n正文", "   # 发布流程 ###\n正文", "#\t发布流程\n正文"] {
      XCTAssertEqual(try removingTitle("发布流程", from: body), "正文")
    }
    XCTAssertNil(MarkdownDuplicateTitleService.duplicateTitleRange(in: "# 发布流程###", title: "发布流程"))
    XCTAssertNotNil(
      MarkdownDuplicateTitleService.duplicateTitleRange(in: "# 发布流程###", title: "发布流程###"))
  }

  func testRemovesSetextLevelOneAsOneEdit() throws {
    for underline in ["=", "===", "  =====  "] {
      XCTAssertEqual(try removingTitle("发布流程", from: "发布流程\n\(underline)\n正文"), "正文")
    }
    XCTAssertEqual(try removingTitle("发布流程", from: "发布流程\n===\n\n正文"), "\n正文")
  }

  func testPreservesCRLFAndUnicodeContentWithoutNormalization() throws {
    let body = "\r\n# 标题 😀 café\r\n\r\n正文 👩🏽‍💻\r\n"
    XCTAssertEqual(try removingTitle("标题 😀 café", from: body), "\r\n\r\n正文 👩🏽‍💻\r\n")
    XCTAssertEqual(
      try removingTitle("标题 😀", from: "标题 😀\r\n===\r\n连续正文\r\n"), "连续正文\r\n"
    )
    XCTAssertEqual(try removingTitle("café", from: "cafe\u{301}\n正文"), "正文")
  }

  func testRejectsEmptyMultilineAndDifferentTitles() {
    for title in ["", " \n\t", "First\nSecond", "发布", "发布流程！", "TITLE"] {
      XCTAssertNil(MarkdownDuplicateTitleService.duplicateTitleRange(in: "发布流程\n正文", title: title))
    }
    XCTAssertNil(MarkdownDuplicateTitleService.duplicateTitleRange(in: "title\n正文", title: "TITLE"))
    XCTAssertNil(MarkdownDuplicateTitleService.duplicateTitleRange(in: "\n \n", title: "发布流程"))
  }

  func testDoesNotDeleteSectionsCodeFrontMatterOrLaterTitles() {
    for body in [
      "## 发布流程\n正文", "### 发布流程\n正文", "发布流程\n---\n正文",
      "    发布流程\n正文", "\t发布流程\n正文", "```\n发布流程\n```",
      " \t发布流程\n正文", "  \t发布流程\n正文", "   \t发布流程\n正文",
      "~~~\n发布流程\n~~~", "---\ntitle: 发布流程\n---\n发布流程",
      "+++\ntitle = '发布流程'\n+++\n发布流程", "> 发布流程\n正文",
      "正文\n# 发布流程", "前言\n\n发布流程\n正文",
    ] {
      XCTAssertNil(MarkdownDuplicateTitleService.duplicateTitleRange(in: body, title: "发布流程"), body)
    }
    for title in ["- Title", "1. Title", "1) Title", "> Title", "___", "###"] {
      XCTAssertNil(
        MarkdownDuplicateTitleService.duplicateTitleRange(in: title + "\nBody", title: title))
    }
    XCTAssertNil(MarkdownDuplicateTitleService.duplicateTitleRange(in: "# ###\nBody", title: "###"))
  }

  func testMixedIndentationOnSetextUnderlinePreservesIndentedCode() throws {
    for indent in [" \t", "  \t", "   \t"] {
      XCTAssertEqual(
        try removingTitle("Title", from: "Title\n\(indent)===\nBody"),
        "\(indent)===\nBody"
      )
    }
  }

  func testPlainTextMatchingTrimsOnlySurroundingWhitespace() throws {
    XCTAssertEqual(try removingTitle(" 发布 流程 ", from: "  发布 流程  \n正文"), "正文")
    XCTAssertNil(
      MarkdownDuplicateTitleService.duplicateTitleRange(in: "发布  流程\n正文", title: "发布 流程"))
  }

  func testSelectionTracksSurvivingTextAcrossRemoval() throws {
    let body = "\n# 😀\n正文文字"
    let titleRange = try XCTUnwrap(
      MarkdownDuplicateTitleService.duplicateTitleRange(in: body, title: "😀"))
    let paragraph = (body as NSString).range(of: "正文")
    let cases: [(NSRange, NSRange)] = [
      (NSRange(location: 0, length: 0), NSRange(location: 0, length: 0)),
      (NSRange(location: 2, length: 2), NSRange(location: 1, length: 0)),
      (paragraph, NSRange(location: 1, length: 2)),
      (NSRange(location: 0, length: NSMaxRange(paragraph)), NSRange(location: 0, length: 3)),
    ]
    for (selection, expected) in cases {
      let edit = try XCTUnwrap(
        MarkdownDuplicateTitleService.removalEdit(in: body, title: "😀", selectedRange: selection))
      XCTAssertEqual(edit.replacedRange, titleRange)
      XCTAssertEqual(edit.selectedRange, expected)
    }
  }

  private func removingTitle(_ title: String, from body: String) throws -> String {
    let edit = try XCTUnwrap(
      MarkdownDuplicateTitleService.removalEdit(
        in: body, title: title, selectedRange: NSRange(location: 0, length: 0)
      ))
    return (body as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
  }
}
