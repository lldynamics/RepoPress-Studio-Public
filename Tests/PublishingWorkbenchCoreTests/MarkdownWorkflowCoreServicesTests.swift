import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class MarkdownWorkflowCoreServicesTests: XCTestCase {
  func testBatchReplacePlansWholeWordCaseInsensitivePreviews() throws {
    let firstID = UUID()
    let secondID = UUID()
    let service = MarkdownBatchFindReplacePlanningService()
    let plan = try service.plan(
      documents: [
        MarkdownBatchReplaceDocument(
          id: firstID,
          title: "第一篇",
          markdown: "Cat cat scatter cat1 CAT."
        ),
        MarkdownBatchReplaceDocument(
          id: secondID,
          title: "第二篇",
          markdown: "没有匹配"
        ),
      ],
      query: "cat",
      replacement: "dog",
      options: MarkdownFindOptions(
        caseSensitive: false,
        wholeWord: true,
        usesRegularExpression: false
      )
    )

    XCTAssertEqual(plan.previews.map(\.status), [.ready, .noMatches])
    XCTAssertEqual(plan.previews.first?.matchCount, 3)
    XCTAssertEqual(plan.previews.first?.proposedMarkdown, "dog dog scatter cat1 dog.")
    XCTAssertEqual(plan.totalMatchCount, 3)
    XCTAssertFalse(plan.hasConflicts)
  }

  func testBatchReplaceSupportsRegularExpressionCapturesAndNoChange() throws {
    let service = MarkdownBatchFindReplacePlanningService()
    let regexPlan = try service.plan(
      documents: [
        MarkdownBatchReplaceDocument(
          id: UUID(),
          title: "标题",
          markdown: "# 第一节\n正文\n# 第二节"
        )
      ],
      query: #"(?m)^# (.+)$"#,
      replacement: "## $1",
      options: MarkdownFindOptions(
        caseSensitive: true,
        wholeWord: false,
        usesRegularExpression: true
      )
    )
    XCTAssertEqual(regexPlan.previews.first?.matchCount, 2)
    XCTAssertEqual(regexPlan.previews.first?.proposedMarkdown, "## 第一节\n正文\n## 第二节")

    let unchangedPlan = try service.plan(
      documents: [
        MarkdownBatchReplaceDocument(id: UUID(), title: "未变化", markdown: "foo")
      ],
      query: "foo",
      replacement: "foo"
    )
    XCTAssertEqual(unchangedPlan.previews.first?.status, .noChange)
    XCTAssertNil(unchangedPlan.previews.first?.edit)
  }

  func testBatchReplaceDetectsStaleAndDuplicateDocuments() throws {
    let id = UUID()
    let baseline = MarkdownBatchReplaceOriginalSnapshot(
      documentID: id,
      title: "文章",
      markdown: "原文 foo"
    )
    let service = MarkdownBatchFindReplacePlanningService()
    let stale = try service.plan(
      documents: [
        MarkdownBatchReplaceDocument(id: id, title: "文章", markdown: "后来编辑的 foo")
      ],
      query: "foo",
      replacement: "bar",
      expectedOriginals: [baseline]
    )
    XCTAssertEqual(
      stale.previews.first?.status,
      .conflict(.sourceChangedSincePreview)
    )

    let duplicate = try service.plan(
      documents: [
        MarkdownBatchReplaceDocument(id: id, title: "文章 A", markdown: "foo"),
        MarkdownBatchReplaceDocument(id: id, title: "文章 B", markdown: "foo"),
      ],
      query: "foo",
      replacement: "bar"
    )
    XCTAssertEqual(
      duplicate.previews.map(\.status),
      [
        .conflict(.duplicateDocumentIdentifier),
        .conflict(.duplicateDocumentIdentifier),
      ]
    )
  }

  func testBatchRollbackOnlyRestoresExactAppliedOutput() throws {
    let id = UUID()
    let service = MarkdownBatchFindReplacePlanningService()
    let appliedPlan = try service.plan(
      documents: [
        MarkdownBatchReplaceDocument(id: id, title: "文章", markdown: "foo foo")
      ],
      query: "foo",
      replacement: "bar"
    )

    let ready = service.rollbackPlan(
      currentDocuments: [
        MarkdownBatchReplaceDocument(id: id, title: "文章", markdown: "bar bar")
      ],
      appliedPlan: appliedPlan
    )
    XCTAssertEqual(ready.previews.first?.status, .ready)
    XCTAssertEqual(ready.previews.first?.restoredMarkdown, "foo foo")
    XCTAssertEqual(ready.previews.first?.edit?.replacement, "foo foo")

    let conflict = service.rollbackPlan(
      currentDocuments: [
        MarkdownBatchReplaceDocument(id: id, title: "文章", markdown: "bar bar\n新编辑")
      ],
      appliedPlan: appliedPlan
    )
    XCTAssertEqual(
      conflict.previews.first?.status,
      .conflict(.documentChangedAfterReplacement)
    )

    let restored = service.rollbackPlan(
      currentDocuments: [
        MarkdownBatchReplaceDocument(id: id, title: "文章", markdown: "foo foo")
      ],
      appliedPlan: appliedPlan
    )
    XCTAssertEqual(restored.previews.first?.status, .alreadyRestored)
  }

  func testSlashCompletionExposesFourRequiredCommandsAndStaleGuard() throws {
    let service = MarkdownCursorCompletionService()
    let all = try XCTUnwrap(
      service.completion(
        in: "/",
        selectedRange: NSRange(location: 1, length: 0)
      )
    )
    XCTAssertEqual(
      Set(all.candidates.map(\.id)),
      Set(["slash-table", "slash-code", "slash-image", "slash-footnote"])
    )

    let source = "/表"
    let tableContext = try XCTUnwrap(
      service.completion(
        in: source,
        selectedRange: NSRange(location: (source as NSString).length, length: 0)
      )
    )
    let table = try XCTUnwrap(tableContext.candidates.first { $0.id == "slash-table" })
    let edit = try XCTUnwrap(service.edit(applying: table, in: source))
    XCTAssertTrue(edit.replacement.hasPrefix("| 列 1 |"))
    XCTAssertEqual(
      (edit.replacement as NSString).substring(
        with: NSRange(
          location: edit.selectedRange.location - edit.replacedRange.location,
          length: edit.selectedRange.length
        )
      ),
      "列 1"
    )
    XCTAssertNil(service.edit(applying: table, in: "/不同"))
  }

  func testFootnoteCompletionChoosesUnusedNumericIdentifier() throws {
    let markdown = "已有[^2]\n\n/脚注"
    let service = MarkdownCursorCompletionService()
    let context = try XCTUnwrap(
      service.completion(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0)
      )
    )
    let candidate = try XCTUnwrap(context.candidates.first)
    XCTAssertTrue(candidate.replacement.contains("[^3]"))
    XCTAssertTrue(candidate.replacement.contains("[^3]:"))
  }

  func testInternalLinkCompletionHandlesOpenAndClosedWikiSyntax() throws {
    let article = MarkdownCompletionArticle(
      id: UUID(),
      title: "发布流程",
      slug: "publish-flow",
      destination: "/posts/publish-flow/"
    )
    let service = MarkdownCursorCompletionService()
    let openSource = "参见 [[发]]"
    let closingLocation = (openSource as NSString).range(of: "]]").location
    let openContext = try XCTUnwrap(
      service.completion(
        in: openSource,
        selectedRange: NSRange(location: closingLocation, length: 0),
        articles: [article]
      )
    )
    let candidate = try XCTUnwrap(openContext.candidates.first)
    XCTAssertEqual(candidate.expectedText, "[[发]]")
    let edit = try XCTUnwrap(service.edit(applying: candidate, in: openSource))
    let replaced = (openSource as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
    XCTAssertEqual(replaced, "参见 [发布流程](/posts/publish-flow/)")

    let closedSource = "参见 [[发布流程]]"
    let closed = try XCTUnwrap(
      service.completion(
        in: closedSource,
        selectedRange: NSRange(location: (closedSource as NSString).length, length: 0),
        articles: [article]
      )
    )
    XCTAssertEqual(closed.query, "发布流程")
  }

  func testCodeLanguageCompletionAndCodeBlockSuppression() throws {
    let markdown = "```sw\nlet value = 1\n```"
    let cursor = (markdown as NSString).range(of: "sw").upperBound
    let service = MarkdownCursorCompletionService()
    let context = try XCTUnwrap(
      service.completion(
        in: markdown,
        selectedRange: NSRange(location: cursor, length: 0)
      )
    )
    XCTAssertEqual(context.kind, .codeLanguage)
    let swift = try XCTUnwrap(context.candidates.first { $0.id == "language-swift" })
    let edit = try XCTUnwrap(service.edit(applying: swift, in: markdown))
    XCTAssertEqual(
      (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement),
      "```swift\nlet value = 1\n```"
    )

    let slashInsideFence = "```\n/表格\n```"
    let slashCursor = (slashInsideFence as NSString).range(of: "/表格").upperBound
    XCTAssertNil(
      service.completion(
        in: slashInsideFence,
        selectedRange: NSRange(location: slashCursor, length: 0)
      )
    )
  }

  func testCursorPositionUsesGraphemeColumnAndTracksUTF16Column() throws {
    let markdown = "😀a\r\n二\n"
    let service = MarkdownCursorContextService()
    let lines = service.lineLocations(in: markdown)
    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(lines.map(\.lineNumber), [1, 2, 3])

    let position = try XCTUnwrap(
      service.position(
        in: markdown,
        selectedRange: NSRange(location: 2, length: 0)
      )
    )
    XCTAssertEqual(position.line, 1)
    XCTAssertEqual(position.column, 2)
    XCTAssertEqual(position.utf16Column, 3)

    let lineTwoEnd = try XCTUnwrap(
      service.jumpTarget(in: markdown, line: 2, column: 2)
    )
    XCTAssertEqual(lineTwoEnd.location, lines[1].contentRange.location + 1)
    XCTAssertNil(service.jumpTarget(in: markdown, line: 4))
  }

  func testFenceMatchingReturnsCounterpartAndUnclosedState() throws {
    let markdown = "正文\n```swift\nlet value = 1\n````   \n结尾"
    let service = MarkdownCursorContextService()
    let match = try XCTUnwrap(service.fenceMatches(in: markdown).first)
    XCTAssertEqual(match.marker, "`")
    XCTAssertEqual(match.markerLength, 3)
    XCTAssertEqual(match.languageHint, "swift")
    XCTAssertEqual(match.openingLine, 2)
    XCTAssertEqual(match.closingLine, 4)
    XCTAssertEqual(match.closingMarkerRange?.length, 4)
    XCTAssertTrue(match.isClosed)
    XCTAssertEqual(
      service.counterpartFenceMarkerRange(
        in: markdown,
        cursorLocation: match.openingMarkerRange.location
      ),
      match.closingMarkerRange
    )

    let unclosed = try XCTUnwrap(
      service.fenceMatches(in: "~~~yaml\nvalue: true").first
    )
    XCTAssertFalse(unclosed.isClosed)
    XCTAssertNil(unclosed.closingLine)
  }

  func testExportPlansAllFormatsWithoutInvokingPlatformUI() throws {
    let service = MarkdownDocumentExportPlanningService()
    let markdown = "# 正文\n\n内容"

    let markdownPlan = try service.plan(
      title: "发布说明",
      markdown: markdown,
      format: .markdown
    )
    XCTAssertEqual(markdownPlan.operation, .writeUTF8File)
    XCTAssertEqual(markdownPlan.suggestedFilename, "发布说明.md")
    XCTAssertEqual(markdownPlan.payload, .text(markdown))

    let htmlPlan = try service.plan(
      title: "<发布>",
      markdown: markdown,
      format: .html
    )
    XCTAssertEqual(htmlPlan.operation, .writeUTF8File)
    guard case .html(let html) = htmlPlan.payload else {
      return XCTFail("HTML 导出应返回 HTML 载荷")
    }
    XCTAssertTrue(html.contains("<title>&lt;发布&gt;</title>"))
    XCTAssertTrue(html.contains("<h1>正文</h1>"))

    XCTAssertEqual(
      try service.plan(title: "PDF", markdown: markdown, format: .pdf).operation,
      .renderHTMLToPDF
    )
    XCTAssertEqual(
      try service.plan(title: "打印", markdown: markdown, format: .print).operation,
      .printHTML
    )
    XCTAssertNil(
      try service.plan(title: "打印", markdown: markdown, format: .print).suggestedFilename
    )
    XCTAssertEqual(
      try service.plan(title: "分享", markdown: markdown, format: .share).operation,
      .shareMarkdown
    )
  }

  func testExportSafeFilenameAndAvailabilityValidation() throws {
    let service = MarkdownDocumentExportPlanningService()
    XCTAssertEqual(
      service.safeFilename(" ../项目:发布/CON?.md ", fileExtension: "md"),
      "项目-发布-CON.md"
    )
    XCTAssertEqual(
      service.safeFilename("CON", fileExtension: "pdf"),
      "CON-document.pdf"
    )
    XCTAssertEqual(
      service.safeFilename("报告", fileExtension: "p/d*f"),
      "报告.pdf"
    )

    let unavailable = service.availability(
      title: "文章",
      markdown: "正文",
      format: .pdf,
      capabilities: MarkdownDocumentExportCapabilities(
        canWriteFiles: false,
        canRenderPDF: false
      )
    )
    XCTAssertEqual(
      unavailable.issues,
      [.fileWritingUnavailable, .pdfRenderingUnavailable]
    )
    XCTAssertThrowsError(
      try service.plan(
        title: "",
        markdown: " \n ",
        format: .share
      )
    ) { error in
      XCTAssertEqual(
        error as? MarkdownDocumentExportPlanningError,
        .unavailable([.emptyDocument])
      )
    }
  }
}

extension NSRange {
  fileprivate var upperBound: Int {
    NSMaxRange(self)
  }
}
