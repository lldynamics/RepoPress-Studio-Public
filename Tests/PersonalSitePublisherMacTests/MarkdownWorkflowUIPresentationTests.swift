import Foundation
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownWorkflowUIPresentationTests: XCTestCase {
  func testBatchPreviewPresentationShowsPerArticleMatchCountAndSourceLine() {
    let documentID = UUID()
    let markdown = "# 标题\n\n原词位于这一行。\n"
    let range = (markdown as NSString).range(of: "原词")
    let snapshot = MarkdownBatchReplaceOriginalSnapshot(
      documentID: documentID,
      title: "文章",
      markdown: markdown
    )
    let preview = MarkdownBatchReplacePreview(
      documentID: documentID,
      title: "文章",
      status: .ready,
      matchRanges: [range],
      originalSnapshot: snapshot,
      proposedMarkdown: markdown.replacingOccurrences(of: "原词", with: "新词"),
      edit: MarkdownSmartEdit(
        replacedRange: range,
        replacement: "新词",
        selectedRange: NSRange(location: range.location + 2, length: 0)
      )
    )

    let presentation = MarkdownBatchReplacePreviewPresentation(preview: preview)

    XCTAssertEqual(presentation.statusText, "1 处匹配")
    XCTAssertEqual(presentation.sourceExcerpt, "原词位于这一行。")
  }

  func testBatchPreviewPresentationExplainsSnapshotConflict() {
    let documentID = UUID()
    let snapshot = MarkdownBatchReplaceOriginalSnapshot(
      documentID: documentID,
      title: "文章",
      markdown: "正文"
    )
    let preview = MarkdownBatchReplacePreview(
      documentID: documentID,
      title: "文章",
      status: .conflict(.sourceChangedSincePreview),
      matchRanges: [],
      originalSnapshot: snapshot,
      proposedMarkdown: "正文",
      edit: nil
    )

    let presentation = MarkdownBatchReplacePreviewPresentation(preview: preview)

    XCTAssertEqual(presentation.statusText, "正文已变化")
    XCTAssertNil(presentation.sourceExcerpt)
  }

  @MainActor
  func testExportExecutorUsesTheValidatedPlanPayloadWithoutReRendering() throws {
    let markdown = "# 标题\n\n正文"
    let plan = try MarkdownDocumentExportPlanningService().plan(
      title: "测试",
      markdown: markdown,
      format: .markdown
    )

    let data = try MarkdownDocumentExportExecutor.fileData(for: plan)

    XCTAssertEqual(String(decoding: data, as: UTF8.self), markdown)
  }

  func testCompletionTriggersExposeEveryDiscoverableWorkflow() {
    XCTAssertEqual(
      Set(MarkdownCompletionTrigger.allCases),
      Set([.slash, .internalLink, .codeLanguage])
    )
    XCTAssertTrue(MarkdownCompletionTrigger.slash.title.contains("/表格"))
    XCTAssertTrue(MarkdownCompletionTrigger.internalLink.title.contains("[[文章]]"))
    XCTAssertTrue(MarkdownCompletionTrigger.codeLanguage.title.contains("```swift"))
  }

  func testBlockCompletionTriggerStartsOnANewLineWithoutInterceptingKeyEvents() {
    let source = "已有正文" as NSString

    let insertion = MarkdownCompletionTrigger.codeLanguage.insertion(
      in: source,
      selectedRange: NSRange(location: source.length, length: 0)
    )

    XCTAssertEqual(insertion.text, "\n```")
    XCTAssertEqual(insertion.caretUTF16Offset, 4)
  }
}
