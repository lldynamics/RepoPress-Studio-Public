import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownBatchFindReplacePlanningServiceTests: XCTestCase {
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
}
