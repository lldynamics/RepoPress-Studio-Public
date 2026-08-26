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
