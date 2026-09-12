import AppKit
import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditableOverlayGeometryTests: XCTestCase {
  func testEditableTextKit2OverlayGeometryFollowsPostReflowTaskAndImageLines() throws {
    let body = """
    😀 编辑器几何回归

    > 引用块在任务之前。
    - [ ] 审阅原生任务复选框
      - [x] 嵌套任务保持缩进
    10. 两位数序号进入编辑时恢复源码

    ```swift
    let renderer = TextKitRenderer()
    ```

    ![发布预览](cover.png)
    - [ ] 图片后的任务必须位于卡片之后。
    - 图片后的普通列表必须位于卡片之后。
    """
    let source = "---\ntitle = \"Unicode 😀\"\n---\n" + body
    let bodyOffset = (source as NSString).range(of: body).location
    let fixtureURL = try makePNGFixture()
    defer { try? FileManager.default.removeItem(at: fixtureURL) }

    let coordinator = makeCoordinator(
      source: source,
      bodyMarkdown: body,
      bodyUTF16Offset: bodyOffset
    )
    coordinator.attachments = [
      DraftAttachment(
        originalFilename: "cover.png",
        relativePublishPath: "cover.png",
        repositoryPath: "cover.png",
        sourceFilePath: fixtureURL.path
      )
    ]

    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: NSRect(x: 0, y: 0, width: 700, height: 900),
      containerSize: NSSize(width: 700, height: 900)
    )
    textView.string = source
    textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

    let sourceText = source as NSString
    let taskMarkerRange = sourceText.range(of: "- [ ] ")
    let taskContentRange = NSRange(location: NSMaxRange(taskMarkerRange), length: 1)
    let nestedTaskMarkerRange = sourceText.range(of: "  - [x] ")
    let nestedTaskContentRange = NSRange(
      location: NSMaxRange(nestedTaskMarkerRange), length: 1
    )
    let postImageTaskLineRange = sourceText.range(of: "- [ ] 图片后的任务")
    let postImageTaskMarkerRange = sourceText.range(
      of: "- [ ] ",
      options: [],
      range: postImageTaskLineRange
    )
    let postImageTaskContentRange = NSRange(
      location: NSMaxRange(postImageTaskMarkerRange),
      length: 1
    )
    let postImageBulletLineRange = sourceText.range(of: "- 图片后的普通列表")
    let postImageBulletMarkerRange = sourceText.range(
      of: "- ",
      options: [],
      range: postImageBulletLineRange
    )
    let postImageBulletContentRange = NSRange(
      location: NSMaxRange(postImageBulletMarkerRange),
      length: 1
    )
    let taskMarker = MarkdownSyntaxMarker(
      range: taskMarkerRange,
      presentation: .taskList(isChecked: false)
    )
    let nestedTaskMarker = MarkdownSyntaxMarker(
      range: nestedTaskMarkerRange,
      presentation: .taskList(isChecked: true)
    )
    let postImageTaskMarker = MarkdownSyntaxMarker(
      range: postImageTaskMarkerRange,
      presentation: .taskList(isChecked: false)
    )
    let postImageBulletMarker = MarkdownSyntaxMarker(
      range: postImageBulletMarkerRange,
      presentation: .unorderedList
    )

    // This mirrors the syntax pass: changing the marker font invalidates the
    // fragment before the checkbox frame is requested.
    textView.textStorage?.addAttribute(
      .font,
      value: coordinator.syntaxHighlightPalette.inactiveTaskMarkerLayoutFont,
      range: taskMarkerRange
    )
    textView.textStorage?.addAttribute(
      .font,
      value: coordinator.syntaxHighlightPalette.inactiveTaskMarkerLayoutFont,
      range: nestedTaskMarkerRange
    )
    textView.textStorage?.addAttribute(
      .font,
      value: coordinator.syntaxHighlightPalette.inactiveTaskMarkerLayoutFont,
      range: postImageTaskLineRange
    )
    coordinator.applyBlockMarkerDrawings(
      [taskMarker, nestedTaskMarker, postImageTaskMarker, postImageBulletMarker],
      in: textView
    )
    let taskDrawing = try XCTUnwrap(
      textView.markdownBlockMarkerDrawings.first { $0.marker.range == taskMarkerRange }
    )
    let nestedTaskDrawing = try XCTUnwrap(
      textView.markdownBlockMarkerDrawings.first { $0.marker.range == nestedTaskMarkerRange }
    )
    let taskContentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: taskContentRange, in: textView)
    )
    let nestedTaskContentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: nestedTaskContentRange, in: textView)
    )
    XCTAssertEqual(taskDrawing.frame.midY, taskContentRect.midY, accuracy: 1)
    XCTAssertLessThan(taskDrawing.frame.maxX, taskContentRect.minX)
    XCTAssertLessThan(try XCTUnwrap(taskDrawing.taskHitFrame).maxX, taskContentRect.minX)
    XCTAssertEqual(nestedTaskDrawing.frame.midY, nestedTaskContentRect.midY, accuracy: 1)
    XCTAssertLessThan(nestedTaskDrawing.frame.maxX, nestedTaskContentRect.minX)
    XCTAssertLessThan(
      try XCTUnwrap(nestedTaskDrawing.taskHitFrame).maxX,
      nestedTaskContentRect.minX
    )
    XCTAssertGreaterThan(nestedTaskDrawing.frame.minX, taskDrawing.frame.minX)

    let applicationRange = NSRange(location: 0, length: sourceText.length)
    coordinator.applyInlineAttachmentDrawings(
      in: textView,
      applicationRange: applicationRange
    )

    let imageRange = sourceText.range(of: "![发布预览](cover.png)")
    let imageKey = "attachment:\(imageRange.location)"
    let imageDrawing = try XCTUnwrap(coordinator.inlineAttachmentDrawingDescriptors[imageKey])
    let imageSourceRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: imageRange, in: textView)
    )
    let codeRange = sourceText.range(of: "let renderer = TextKitRenderer()")
    let codeRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: codeRange, in: textView)
    )
    let postImageTaskContentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: postImageTaskContentRange, in: textView)
    )
    let postImageBulletContentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: postImageBulletContentRange, in: textView)
    )
    let postImageTaskDrawing = try XCTUnwrap(
      textView.markdownBlockMarkerDrawings.first { $0.marker.range == postImageTaskMarkerRange }
    )
    let postImageBulletDrawing = try XCTUnwrap(
      textView.markdownBlockMarkerDrawings.first { $0.marker.range == postImageBulletMarkerRange }
    )

    XCTAssertEqual(imageDrawing.frame.midY, imageSourceRect.midY, accuracy: 1)
    XCTAssertLessThan(codeRect.maxY, imageDrawing.frame.minY)
    XCTAssertLessThanOrEqual(imageDrawing.frame.maxY, postImageTaskContentRect.minY + 1)
    XCTAssertEqual(postImageTaskDrawing.frame.midY, postImageTaskContentRect.midY, accuracy: 1)
    XCTAssertLessThan(postImageTaskDrawing.frame.maxX, postImageTaskContentRect.minX)
    XCTAssertGreaterThanOrEqual(postImageTaskDrawing.frame.minY, imageDrawing.frame.maxY - 1)
    XCTAssertEqual(postImageBulletDrawing.frame.midY, postImageBulletContentRect.midY, accuracy: 1)
    XCTAssertLessThanOrEqual(postImageBulletDrawing.frame.maxX, postImageBulletContentRect.minX)
    XCTAssertGreaterThanOrEqual(postImageBulletDrawing.frame.minY, imageDrawing.frame.maxY - 1)
  }

  private func makeCoordinator(
    source: String,
    bodyMarkdown: String,
    bodyUTF16Offset: Int
  ) -> MacMarkdownTextView.Coordinator {
    var boundText = source
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    return MacMarkdownTextView.Coordinator(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      selectedRange: Binding(get: { selectedRange }, set: { selectedRange = $0 }),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection }, set: { isFrontMatterSelection = $0 }),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { _ in },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
  }

  private func makePNGFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownEditableOverlayGeometry-\(UUID().uuidString).png")
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url, options: .atomic)
    return url
  }
}
