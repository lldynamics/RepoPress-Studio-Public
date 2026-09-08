import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSDraftInsertionTargetTests: XCTestCase {
  @MainActor
  func testCapturedTargetWritesOriginalDraftAfterSelectionChanges() throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    let original = try makeDraft(named: "原文章", body: "原始正文", in: store)
    store.updateActiveEditorSelection(
      draftID: original.id,
      selectedRange: NSRange(location: 0, length: 0),
      selectedText: "",
      bodyUTF16Count: original.bodyMarkdown.utf16.count
    )
    let target = try XCTUnwrap(
      KnowledgeArticleInsertionService.captureRSSDraftInsertionTarget(in: store)
    )
    let laterSelection = try makeDraft(named: "后来选择的文章", body: "不要写这里", in: store)

    XCTAssertTrue(
      KnowledgeArticleInsertionService.insertRSSReference(
        article: article(),
        summary: "安全摘要",
        excerpt: "可核对摘录",
        citation: nil,
        targeting: target,
        into: store
      )
    )

    XCTAssertEqual(store.selectedDraftID, laterSelection.id)
    XCTAssertTrue(draft(original.id, in: store).bodyMarkdown.hasPrefix("### 目标写入测试"))
    XCTAssertTrue(draft(original.id, in: store).bodyMarkdown.contains("安全摘要"))
    XCTAssertFalse(draft(laterSelection.id, in: store).bodyMarkdown.contains("安全摘要"))
  }

  @MainActor
  func testCapturedTargetRejectsOriginalDraftChangedWhileAwaiting() throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    let original = try makeDraft(named: "原文章", body: "原始正文", in: store)
    let target = try XCTUnwrap(
      KnowledgeArticleInsertionService.captureRSSDraftInsertionTarget(in: store)
    )
    var changed = draft(original.id, in: store)
    changed.bodyMarkdown = "另一窗口的新正文"
    store.updateDraft(changed)
    XCTAssertNotEqual(store.draftBodyEditorBuffer(for: original.id).revision, target.bodyRevision)

    XCTAssertFalse(
      KnowledgeArticleInsertionService.insertRSSReference(
        article: article(),
        summary: "不应写入",
        excerpt: "不应写入",
        citation: nil,
        targeting: target,
        into: store
      )
    )
    XCTAssertEqual(draft(original.id, in: store).bodyMarkdown, "另一窗口的新正文")
  }

  @MainActor
  func testCapturedTargetRejectsDeletedOriginalWithoutWritingCurrentDraft() throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    let original = try makeDraft(named: "原文章", body: "原始正文", in: store)
    let target = try XCTUnwrap(
      KnowledgeArticleInsertionService.captureRSSDraftInsertionTarget(in: store)
    )
    let laterSelection = try makeDraft(named: "保留文章", body: "保持不变", in: store)
    store.deleteDraft(id: original.id)

    XCTAssertFalse(
      KnowledgeArticleInsertionService.insertRSSReference(
        article: article(),
        summary: "不应写入",
        excerpt: "不应写入",
        citation: nil,
        targeting: target,
        into: store
      )
    )
    XCTAssertEqual(store.selectedDraftID, laterSelection.id)
    XCTAssertEqual(draft(laterSelection.id, in: store).bodyMarkdown, "保持不变")
  }

  @MainActor
  func testCapturedTargetRejectsSiteProfileMismatchWithoutWriting() throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    let original = try makeDraft(named: "原文章", body: "原始正文", in: store)
    let captured = try XCTUnwrap(
      KnowledgeArticleInsertionService.captureRSSDraftInsertionTarget(in: store)
    )
    let mismatchedTarget = RSSDraftInsertionTarget(
      draftID: captured.draftID,
      siteProfileID: UUID(),
      bodyMarkdown: captured.bodyMarkdown,
      bodyRevision: captured.bodyRevision,
      selectionRange: captured.selectionRange
    )

    XCTAssertFalse(
      KnowledgeArticleInsertionService.insertRSSReference(
        article: article(),
        summary: "不应写入",
        excerpt: "不应写入",
        citation: nil,
        targeting: mismatchedTarget,
        into: store
      )
    )
    XCTAssertEqual(draft(original.id, in: store).bodyMarkdown, "原始正文")
  }

  @MainActor
  func testNewGeneralDraftTargetRemainsFixedAfterAnotherSelection() throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    store.createGeneralDraft()
    let inspiration = try XCTUnwrap(store.selectedDraft)
    let target = try XCTUnwrap(
      KnowledgeArticleInsertionService.captureRSSDraftInsertionTarget(in: store)
    )
    let laterSelection = try makeDraft(named: "后来文章", body: "不要写这里", in: store)

    XCTAssertEqual(target.draftID, inspiration.id)
    XCTAssertTrue(
      KnowledgeArticleInsertionService.insertRSSReference(
        article: article(),
        summary: "灵感摘要",
        excerpt: "灵感摘录",
        citation: nil,
        appendingFootnote: true,
        targeting: target,
        into: store
      )
    )

    XCTAssertTrue(draft(inspiration.id, in: store).bodyMarkdown.contains("灵感摘要"))
    XCTAssertFalse(draft(laterSelection.id, in: store).bodyMarkdown.contains("灵感摘要"))
  }

  @MainActor
  private func makeStore() throws -> (store: WorkbenchStore, rootURL: URL) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSDraftInsertionTargetTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return (
      WorkbenchStore(
        persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json"))
      ),
      rootURL
    )
  }

  @MainActor
  private func makeDraft(named title: String, body: String, in store: WorkbenchStore) throws -> ArticleDraft {
    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = title
    draft.bodyMarkdown = body
    store.updateDraft(draft)
    store.flushDraftBodyEditorBuffer(for: draft.id)
    return try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))
  }

  @MainActor
  private func draft(_ id: UUID, in store: WorkbenchStore) -> ArticleDraft {
    store.drafts.first(where: { $0.id == id })!
  }

  private func article() -> RSSArticle {
    RSSArticle(
      id: "targeted-rss-reference",
      feedID: UUID(),
      title: "目标写入测试",
      link: URL(string: "https://example.com/targeted-rss-reference"),
      contentHTML: "<p>正文</p>"
    )
  }
}
