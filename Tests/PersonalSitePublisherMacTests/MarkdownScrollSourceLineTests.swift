import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownScrollSourceLineTests: XCTestCase {
  @MainActor
  func testBridgeCanDisableSourceLineReportingWithoutChangingProgressOrRestoration() throws {
    let fixture = try makeFixture()
    var insertionLookupCount = 0
    var appliedSourceLines: [Int] = []
    let bridge = MarkdownScrollViewSyncBridge(source: .editor, onPositionChanged: { _ in })
    bridge.observe(
      fixture.scrollView,
      sourceLineProvider: {
        _ in
        insertionLookupCount += 1
        return self.sourceLine(atVisibleTopOf: fixture.scrollView, textView: fixture.textView)
      },
      sourceLineApplier: { sourceLine, _ in
        appliedSourceLines.append(sourceLine)
        return true
      },
      reportsSourceLine: false
    )
    defer { bridge.invalidate() }

    let position = bridge.reportedPosition(for: fixture.scrollView, progress: 0.42)

    XCTAssertEqual(insertionLookupCount, 0)
    XCTAssertNil(position.sourceLine)
    XCTAssertEqual(position.progress, 0.42, accuracy: 0.0001)

    bridge.restore(MarkdownScrollSyncUpdate(source: .editor, progress: 0.8, sourceLine: 2))
    XCTAssertTrue(appliedSourceLines.isEmpty, "Restoration remains progress-based.")
  }

  @MainActor
  func testBridgeCanReenableSourceLineReportingForAnAccurateAppKitAnchor() throws {
    let fixture = try makeFixture()
    let secondLineRange = (fixture.textView.string as NSString).range(of: "second source line")
    let secondLineRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(for: secondLineRange, in: fixture.textView)
    )
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: secondLineRect.minY))
    fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)

    var insertionLookupCount = 0
    let bridge = MarkdownScrollViewSyncBridge(source: .editor, onPositionChanged: { _ in })
    bridge.observe(
      fixture.scrollView,
      sourceLineProvider: { _ in
        insertionLookupCount += 1
        return self.sourceLine(atVisibleTopOf: fixture.scrollView, textView: fixture.textView)
      },
      reportsSourceLine: false
    )
    defer { bridge.invalidate() }

    XCTAssertNil(bridge.reportedPosition(for: fixture.scrollView, progress: 0.63).sourceLine)
    XCTAssertEqual(insertionLookupCount, 0)

    bridge.setReportsSourceLine(true)
    let position = bridge.reportedPosition(for: fixture.scrollView, progress: 0.63)

    XCTAssertEqual(insertionLookupCount, 1)
    XCTAssertEqual(position.sourceLine, 2)
    XCTAssertEqual(position.progress, 0.63, accuracy: 0.0001)
  }

  @MainActor
  private func makeFixture() throws -> (scrollView: NSScrollView, textView: NSTextView) {
    let source = [
      String(repeating: "A long wrapped first source line ", count: 24),
      "second source line",
      "third source line",
    ].joined(separator: "\n")
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 130))
    let textView = DroppableMarkdownTextView.makeTextKit2(
      frame: NSRect(x: 0, y: 0, width: 260, height: 130),
      containerSize: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
    )
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    textView.string = source
    scrollView.documentView = textView
    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let documentRect = try XCTUnwrap(
      MarkdownTextKit2RangeAdapter.rect(
        for: NSRange(location: 0, length: (source as NSString).length),
        in: textView
      )
    )
    textView.setFrameSize(
      NSSize(width: 260, height: max(130, documentRect.maxY + textView.textContainerInset.height))
    )
    scrollView.layoutSubtreeIfNeeded()
    return (scrollView, textView)
  }

  @MainActor
  private func sourceLine(atVisibleTopOf scrollView: NSScrollView, textView: NSTextView) -> Int {
    let point = NSPoint(
      x: textView.textContainerInset.width + 1,
      y: scrollView.documentVisibleRect.minY + textView.textContainerInset.height + 1
    )
    let location = textView.characterIndexForInsertion(at: point)
    let source = textView.string as NSString
    let prefix = source.substring(to: min(location, source.length))
    return (prefix as NSString).components(separatedBy: "\n").count
  }
}
