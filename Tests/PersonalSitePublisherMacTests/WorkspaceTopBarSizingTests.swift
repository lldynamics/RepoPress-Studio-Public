import Foundation
import XCTest

/// Keeps the toolbar's compact/expanded sizing contract close to its source.
/// These are source-contract checks rather than rendered UI measurements.
final class WorkspaceTopBarSizingTests: XCTestCase {
  func testProfileMenuUsesCompactAndExpandedWidthBands() throws {
    let source = try topBarSource()
    let leadingContent = try section(
      in: source,
      startingAt: "struct WorkspaceToolbarLeadingContent: View {",
      endingAt: "private enum PublishingStatusArea {"
    )
    let normalized = normalize(leadingContent)

    XCTAssertTrue(
      normalized.contains(
        ".frame(minWidth:isCompact?30:nil,maxWidth:isCompact?30:220,minHeight:28,alignment:.leading)"
      )
    )
    XCTAssertFalse(normalized.contains(".frame(width:180"))
  }

  func testProfileMenuBadgeIsSingleLineAndKeepsItsIntrinsicWidth() throws {
    let source = try topBarSource()
    let menuLabel = try section(
      in: source,
      startingAt: "struct WorkspaceToolbarMenuLabel: View {",
      endingAt: "struct WorkspaceTaskCenterToolbarButton: View {"
    )
    let normalized = normalize(menuLabel)

    XCTAssertTrue(normalized.contains("Text(siteKindDisplayName)"))
    XCTAssertTrue(normalized.contains(".lineLimit(1)"))
    XCTAssertTrue(normalized.contains(".fixedSize(horizontal:true,vertical:false)"))
  }

  func testPublishingStatusUsesCompactWidthAndOmitsOnlyCompactStatusText() throws {
    let source = try topBarSource()
    let control = try section(
      in: source,
      startingAt: "struct PublishingStatusToolbarControl: View {",
      endingAt: "private var statusItems"
    )
    let normalized = normalize(control)

    XCTAssertTrue(normalized.contains(".padding(.horizontal,isCompact?0:8)"))
    XCTAssertTrue(
      normalized.contains(
        ".frame(minWidth:isCompact?30:96,maxWidth:isCompact?30:200,minHeight:28)"
      )
    )

    let label = try section(
      in: source,
      startingAt: "private func statusToolbarLabel(_ status: PublishingStatusPopoverItem) -> some View {",
      endingAt: "private var statusItems"
    )
    let normalizedLabel = normalize(label)
    XCTAssertTrue(normalizedLabel.contains("Image(systemName:status.severity.symbol)"))
    XCTAssertTrue(normalizedLabel.contains("if!isCompact{Text(status.value)"))
    XCTAssertTrue(normalizedLabel.contains(".lineLimit(1)"))
    XCTAssertTrue(normalizedLabel.contains(".truncationMode(.tail)"))
    XCTAssertFalse(normalizedLabel.contains("maxWidth:.infinity"))

    XCTAssertTrue(normalized.contains(".help(String(localized:"))
    XCTAssertTrue(normalized.contains("点击查看状态和发布操作。"))
  }

  func testPublishingStatusRetainsFullAccessibilityValueWhenTextIsCompactHidden() throws {
    let source = try topBarSource()
    let control = try section(
      in: source,
      startingAt: "struct PublishingStatusToolbarControl: View {",
      endingAt: "private var statusItems"
    )
    let normalized = normalize(control)

    XCTAssertTrue(
      normalized.contains(
        ".accessibilityValue(\"\\(currentToolbarStatus.area.title)：\\(currentToolbarStatus.value)\")"
      )
    )
  }

  private func topBarSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/PersonalSitePublisherMac/Views/Workspace/WorkspaceTopBarView.swift"
      ),
      encoding: .utf8
    )
  }

  private func section(in source: String, startingAt start: String, endingAt end: String) throws -> String {
    let startRange = try XCTUnwrap(source.range(of: start), "Missing source section start: \(start)")
    let remainder = source[startRange.lowerBound...]
    let endRange = try XCTUnwrap(remainder.range(of: end), "Missing source section end: \(end)")
    return String(remainder[..<endRange.lowerBound])
  }

  private func normalize(_ source: String) -> String {
    source.filter { !$0.isWhitespace }
  }
}
