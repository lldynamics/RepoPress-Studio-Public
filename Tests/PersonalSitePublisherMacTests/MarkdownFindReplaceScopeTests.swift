import Foundation
import PublishingMarkdownCore
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownFindReplaceScopeTests: XCTestCase {
  private let service = MarkdownFindReplaceService()

  func testSelectionScopeFreezesUTF16RangeAndDoesNotFollowLaterCursor() throws {
    let draftID = UUID()
    let body = "开头 😀甲 中间 😀甲 结尾"
    let source = body as NSString
    let frozenRange = source.range(of: "😀甲 中间 😀甲")
    let snapshot = MarkdownFindScopeSnapshot(
      draftID: draftID,
      bodyRevision: 12,
      range: frozenRange,
      selectedText: source.substring(with: frozenRange)
    )

    let scope = try XCTUnwrap(
      MarkdownFindReplaceScopePlanner.scopeRange(
        scope: .selection,
        snapshot: snapshot,
        draftID: draftID,
        bodyRevision: 12,
        body: body
      )
    )
    let matches = try MarkdownFindReplaceScopePlanner.matches(
      in: body,
      scopeRange: scope,
      query: "😀甲",
      options: MarkdownFindOptions(),
      service: service
    )

    XCTAssertEqual(matches.count, 2)
    XCTAssertEqual(matches.first?.location, frozenRange.location)
    XCTAssertEqual(matches.last?.location, frozenRange.location + 7)
  }

  func testSelectionScopeAndPreviewRejectNewBodyRevision() throws {
    let draftID = UUID()
    let body = "前缀 甲甲 后缀"
    let source = body as NSString
    let range = source.range(of: "甲甲")
    let snapshot = MarkdownFindScopeSnapshot(
      draftID: draftID,
      bodyRevision: 3,
      range: range,
      selectedText: "甲甲"
    )
    let preview = try MarkdownFindReplaceScopePlanner.previewReplaceAll(
      in: body,
      draftID: draftID,
      bodyRevision: 3,
      scope: .selection,
      scopeRange: range,
      query: "甲",
      replacement: "乙",
      options: MarkdownFindOptions(),
      service: service
    )

    XCTAssertFalse(snapshot.isValid(for: draftID, bodyRevision: 4, body: body))
    XCTAssertFalse(preview.isValid(for: draftID, bodyRevision: 4, body: body))
    XCTAssertFalse(snapshot.isValid(for: draftID, bodyRevision: 3, body: "前缀 乙甲 后缀"))
    XCTAssertFalse(preview.isValid(for: draftID, bodyRevision: 3, body: "前缀 乙甲 后缀"))
  }

  func testRegexPreviewUsesScopedUTF16TextAndSingleEdit() throws {
    let draftID = UUID()
    let body = "外部 😀甲 内部 😀乙"
    let source = body as NSString
    let range = source.range(of: "😀甲")
    let preview = try MarkdownFindReplaceScopePlanner.previewReplaceAll(
      in: body,
      draftID: draftID,
      bodyRevision: 7,
      scope: .selection,
      scopeRange: range,
      query: "😀(甲)",
      replacement: "$1✨",
      options: MarkdownFindOptions(usesRegularExpression: true),
      service: service
    )

    XCTAssertEqual(preview.replacementCount, 1)
    XCTAssertEqual(preview.originalScope, "😀甲")
    XCTAssertEqual(preview.proposedScope, "甲✨")
    XCTAssertEqual(preview.edit.replacedRange, range)
    XCTAssertEqual(preview.edit.selectedRange, NSRange(location: range.location, length: 0))
  }

  func testBodyPreviewRejectsDifferentTextEvenBeforeRevisionPublication() throws {
    let id = UUID()
    let preview = try MarkdownFindReplaceScopePlanner.previewReplaceAll(
      in: "甲乙", draftID: id, bodyRevision: 1, scope: .body,
      scopeRange: NSRange(location: 0, length: 2), query: "甲", replacement: "一",
      options: MarkdownFindOptions(), service: service
    )
    XCTAssertFalse(preview.isValid(for: id, bodyRevision: 1, body: "甲丙"))
    XCTAssertFalse(preview.isValid(for: UUID(), bodyRevision: 1, body: "甲乙"))
    XCTAssertTrue(preview.isValid(for: id, bodyRevision: 1, body: "甲乙"))
  }

  func testOwnReplacementRebasesSelectionOnlyForItsAcknowledgedRevision() throws {
    let id = UUID()
    let snapshot = MarkdownFindScopeSnapshot(
      draftID: id, bodyRevision: 5, range: NSRange(location: 2, length: 2), selectedText: "甲甲"
    )
    let pending = MarkdownPendingFindReplacement(
      requestID: UUID(), draftID: id, selection: snapshot,
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 2, length: 1), replacement: "😀",
        selectedRange: NSRange(location: 4, length: 0)
      ), count: 1
    )
    let updated = try XCTUnwrap(pending.rebasedSelection(bodyRevision: 6, body: "前缀😀甲后缀"))
    XCTAssertEqual(updated.range, NSRange(location: 2, length: 3))
    XCTAssertEqual(updated.selectedText, "😀甲")
    XCTAssertNil(pending.rebasedSelection(bodyRevision: 7, body: "前缀😀甲后缀"))
    XCTAssertNil(pending.rebasedSelection(bodyRevision: 6, body: "前缀乙甲后缀"))
  }
}

final class MarkdownOutlinePresentationPolicyTests: XCTestCase {
  func testCurrentHeadingUsesCursorLocationAndCollapsedChildrenAreHidden() {
    let items = [
      item(title: "一", level: 1, location: 0),
      item(title: "一点一", level: 2, location: 10),
      item(title: "二", level: 1, location: 20)
    ]

    XCTAssertEqual(
      MarkdownOutlinePresentationPolicy.activeItemID(
        in: items,
        selectedRange: NSRange(location: 14, length: 0)
      ),
      items[1].id
    )
    XCTAssertEqual(
      MarkdownOutlinePresentationPolicy.visibleItems(items, collapsedItemIDs: [items[0].id]).map(\.id),
      [items[0].id, items[2].id]
    )
  }

  func testPinnedOutlineUsesDockOnlyWhenEditorHasEnoughWidth() {
    XCTAssertTrue(
      MarkdownOutlinePresentationPolicy.usesDockedLayout(
        isPinned: true,
        availableWidth: MarkdownOutlinePresentationPolicy.dockMinimumWidth
      )
    )
    XCTAssertFalse(
      MarkdownOutlinePresentationPolicy.usesDockedLayout(
        isPinned: true,
        availableWidth: MarkdownOutlinePresentationPolicy.dockMinimumWidth - 1
      )
    )
    XCTAssertFalse(
      MarkdownOutlinePresentationPolicy.usesDockedLayout(isPinned: false, availableWidth: 2_000)
    )
  }

  private func item(title: String, level: Int, location: Int) -> MarkdownOutlineItem {
    MarkdownOutlineItem(
      level: level,
      title: title,
      headingLocation: location,
      headingLength: 3,
      sectionLocation: location,
      sectionLength: 8,
      publicRiskSummary: PublicRiskSummary(issues: [])
    )
  }
}
