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

  func testCursorWorkflowIncludesOpeningBodyAndClosingFenceLines() throws {
    let markdown = "正文\r\n  ```swift\r\nlet value = 1\r\n  ````  \r\n结尾"
    let service = MarkdownCursorContextService()
    let lines = service.lineLocations(in: markdown)

    for line in lines {
      // Check both the start and the end of each line so indentation,
      // language hints, and closing-fence whitespace remain in the block.
      for location in [line.contentRange.location, NSMaxRange(line.contentRange)] {
        let snapshot = service.snapshot(
          in: markdown,
          selectedRange: NSRange(location: location, length: 0),
          revision: 1
        )
        let match = MarkdownCursorWorkflowPresentation.codeFenceMatch(
          position: snapshot.position,
          fenceMatch: snapshot.fenceMatch
        )

        if (2...4).contains(line.lineNumber) {
          XCTAssertEqual(try XCTUnwrap(match).openingLine, 2)
          XCTAssertEqual(match?.closingLine, 4)
        } else {
          XCTAssertNil(match, "Prose on line \(line.lineNumber) must keep the status bar quiet")
        }
      }
    }
  }

  func testCursorWorkflowHidesFenceWhenSelectionStartsInProseAndIntersectsCode() throws {
    let markdown = "正文\n```swift\nlet value = 1\n```\n结尾"
    let source = markdown as NSString
    let service = MarkdownCursorContextService()
    let snapshot = service.snapshot(
      in: markdown,
      selectedRange: NSRange(location: 0, length: source.range(of: "value").location + 1),
      revision: 1
    )

    XCTAssertNotNil(snapshot.fenceMatch, "The service returns selection intersections")
    XCTAssertNil(
      MarkdownCursorWorkflowPresentation.codeFenceMatch(
        position: snapshot.position,
        fenceMatch: snapshot.fenceMatch
      )
    )
  }

  func testCursorWorkflowHidesFenceOnEmptyLineAfterClosedBlock() {
    let markdown = "```swift\nvalue\n```\n"
    let snapshot = MarkdownCursorContextService().snapshot(
      in: markdown,
      selectedRange: NSRange(location: (markdown as NSString).length, length: 0),
      revision: 1
    )

    XCTAssertEqual(snapshot.position?.line, 4)
    XCTAssertNotNil(snapshot.fenceMatch, "The range lookup includes a fence ending at EOF")
    XCTAssertNil(
      MarkdownCursorWorkflowPresentation.codeFenceMatch(
        position: snapshot.position,
        fenceMatch: snapshot.fenceMatch
      )
    )
  }

  func testCursorWorkflowKeepsUnclosedFenceVisibleAtEndOfDocument() throws {
    for markdown in ["~~~yaml", "~~~yaml\nvalue: true", "~~~yaml\nvalue: true\n"] {
      let snapshot = MarkdownCursorContextService().snapshot(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0),
        revision: 1
      )
      let match = try XCTUnwrap(
        MarkdownCursorWorkflowPresentation.codeFenceMatch(
          position: snapshot.position,
          fenceMatch: snapshot.fenceMatch
        )
      )

      XCTAssertEqual(match.openingLine, 1)
      XCTAssertFalse(match.isClosed)
    }
  }

  func testCursorWorkflowHidesFenceWithoutKnownCursorPosition() throws {
    let match = try XCTUnwrap(
      MarkdownCursorContextService().fenceMatches(in: "```swift\nvalue\n```").first
    )

    XCTAssertNil(
      MarkdownCursorWorkflowPresentation.codeFenceMatch(position: nil, fenceMatch: match)
    )
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
