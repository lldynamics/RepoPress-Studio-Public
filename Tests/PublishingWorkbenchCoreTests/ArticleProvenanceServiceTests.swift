import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class ArticleProvenanceServiceTests: XCTestCase {
  private let service = ArticleProvenanceService()

  func testAIProvenanceAddsOneTagAndManagedDisclosure() {
    let draft = makeDraft(tags: ["Swift", "AI辅助"], body: "# 正文\n\n内容")

    let result = service.applying(.aiAuthored, to: draft)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.tags, ["Swift", "AI主笔"])
    XCTAssertTrue(
      result.draft.bodyMarkdown.hasPrefix(ArticleProvenanceService.managedDisclosureStart)
    )
    XCTAssertTrue(result.draft.bodyMarkdown.contains("> 创作说明：本文主要由 AI 生成"))
    XCTAssertTrue(result.draft.bodyMarkdown.hasSuffix("# 正文\n\n内容"))
  }

  func testRepeatedApplicationIsIdempotent() {
    let first = service.applying(
      .hybrid,
      to: makeDraft(tags: ["产品"], body: "正文")
    ).draft

    let second = service.applying(.hybrid, to: first)

    XCTAssertTrue(second.isValid)
    XCTAssertEqual(second.draft, first)
    let markerComponents = second.draft.bodyMarkdown.components(
      separatedBy: ArticleProvenanceService.managedDisclosureStart
    )
    XCTAssertEqual(
      markerComponents.count,
      2
    )
  }

  func testProvenanceCanRecoverFromManagedDisclosureWhenTagIsMissing() {
    let marked = service.applying(
      .hybrid,
      to: makeDraft(tags: ["产品"], body: "正文")
    ).draft
    var missingTag = marked
    missingTag.tags = ["产品"]

    XCTAssertEqual(service.provenance(for: missingTag), .hybrid)
  }

  func testHumanOriginalRemovesOnlyProvenanceTagAndManagedDisclosure() {
    let marked = service.applying(
      .aiAssisted,
      to: makeDraft(tags: ["macOS", "教程"], body: "正文")
    ).draft

    let result = service.applying(.humanOriginal, to: marked)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.tags, ["macOS", "教程"])
    XCTAssertEqual(result.draft.bodyMarkdown, "正文")
  }

  func testHumanOriginalPreservesUnmanagedDisclosureWithoutProvenanceTag() {
    let body = "> 创作说明：这里是作者自己写的提示。\n\n正文"
    let draft = makeDraft(tags: ["随笔"], body: body)

    let result = service.applying(.humanOriginal, to: draft)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.bodyMarkdown, body)
    XCTAssertEqual(result.draft.tags, ["随笔"])
  }

  func testHumanOriginalRemovesTaggedLegacyDisclosure() {
    let draft = makeDraft(
      tags: ["教程", "人机混合"],
      body: "> 创作说明：正文主要由 AI 撰写，文末为作者本人补充。\n\n正文"
    )

    let result = service.applying(.humanOriginal, to: draft)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.tags, ["教程"])
    XCTAssertEqual(result.draft.bodyMarkdown, "正文")
  }

  func testExistingTaggedLegacyDisclosureIsMigrated() {
    let draft = makeDraft(
      tags: ["人机混合", "随笔"],
      body: "> 创作说明：正文主要由 AI 撰写，文末为作者本人补充。\n\n正文"
    )

    let result = service.applying(.aiAssisted, to: draft)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.tags, ["随笔", "AI辅助"])
    XCTAssertTrue(
      result.draft.bodyMarkdown.hasPrefix(ArticleProvenanceService.managedDisclosureStart)
    )
    XCTAssertFalse(result.draft.bodyMarkdown.contains("文末为作者本人补充"))
  }

  func testMalformedManagedDisclosureFailsClosed() {
    let body = [
      ArticleProvenanceService.managedDisclosureStart,
      "> 创作说明：损坏的标记",
      "正文",
    ].joined(separator: "\n")
    let draft = makeDraft(tags: ["随笔"], body: body)

    let result = service.applying(.aiAuthored, to: draft)

    XCTAssertEqual(result.issue, .malformedManagedDisclosure)
    XCTAssertEqual(result.draft, draft)
  }

  private func makeDraft(tags: [String], body: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: UUID(),
      title: "测试文章",
      slug: "test-article",
      tags: tags,
      bodyMarkdown: body
    )
  }
}

@MainActor
final class WorkbenchStoreArticleProvenanceTests: XCTestCase {
  func testStoreAppliesProvenanceToLatestDirtyEditorBody() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPress-Provenance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      safeMode: true
    )
    let initialDraft = try XCTUnwrap(store.selectedDraft)
    var metadata = initialDraft
    metadata.tags = ["移动端", "Git"]
    store.updateDraft(metadata)

    let buffer = store.draftBodyEditorBuffer(for: initialDraft.id)
    let latestBody = "正在编辑但尚未自动保存的正文"
    let staged = try XCTUnwrap(
      store.stageDraftBody(
        latestBody,
        for: initialDraft.id,
        baseRevision: buffer.revision
      )
    )
    XCTAssertTrue(staged.wasAccepted)

    let result = store.applyArticleProvenance(.hybrid, to: initialDraft.id)

    XCTAssertEqual(result, .applied)
    XCTAssertEqual(store.draft(for: initialDraft.id)?.tags, ["移动端", "Git", "人机混合"])
    let updatedBuffer = store.draftBodyEditorBuffer(for: initialDraft.id)
    XCTAssertTrue(updatedBuffer.bodyMarkdown.contains("正在编辑但尚未自动保存的正文"))
    XCTAssertTrue(
      updatedBuffer.bodyMarkdown.hasPrefix(ArticleProvenanceService.managedDisclosureStart)
    )
    XCTAssertTrue(updatedBuffer.isDirty)
  }
}
