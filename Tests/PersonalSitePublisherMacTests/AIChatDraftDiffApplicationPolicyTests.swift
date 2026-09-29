import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class AIChatDraftDiffApplicationPolicyTests: XCTestCase {
  func testAcceptsUnchangedSourceDraft() {
    let original = makeDraft()
    var updated = original
    updated.bodyMarkdown = "修改后的正文"
    let preview = AIChatDraftDiffPreview(
      originalDraft: original,
      updatedDraft: updated,
      citations: [],
      applicationKind: .structuredEdit
    )

    XCTAssertTrue(
      AIChatDraftDiffApplicationPolicy.canApply(
        currentDraft: original,
        preview: preview
      )
    )
  }

  func testRejectsBodyChangeAfterPreviewOpened() {
    let original = makeDraft()
    var updated = original
    updated.bodyMarkdown = "修改后的正文"
    let preview = AIChatDraftDiffPreview(
      originalDraft: original,
      updatedDraft: updated,
      citations: []
    )
    var current = original
    current.bodyMarkdown = "用户的新正文"

    XCTAssertFalse(
      AIChatDraftDiffApplicationPolicy.canApply(
        currentDraft: current,
        preview: preview
      )
    )
  }

  func testRejectsMetadataChangeAfterPreviewOpened() {
    let original = makeDraft()
    var updated = original
    updated.bodyMarkdown = "修改后的正文"
    let preview = AIChatDraftDiffPreview(
      originalDraft: original,
      updatedDraft: updated,
      citations: []
    )
    var current = original
    current.summary = "用户刚更新的摘要"

    XCTAssertFalse(
      AIChatDraftDiffApplicationPolicy.canApply(
        currentDraft: current,
        preview: preview
      )
    )
  }

  func testAppliesPreviewToCurrentDraftWithoutRevertingGoalOrGeneralFolder() throws {
    var original = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      scope: .general,
      generalDraftFolderName: "旧文件夹",
      title: "测试",
      slug: "test",
      bodyMarkdown: "原始正文",
      targetWordCount: 800
    )
    var proposed = original
    proposed.bodyMarkdown = "AI 修改后的正文"
    proposed.summary = "AI 摘要"
    let preview = AIChatDraftDiffPreview(
      originalDraft: original,
      updatedDraft: proposed,
      citations: [],
      applicationKind: .structuredEdit
    )

    // A second window changes settings while the preview remains open.
    original.targetWordCount = 1_200
    original.setGeneralDraftFolderName("新文件夹")
    let applied = try XCTUnwrap(
      AIChatDraftDiffApplicationPolicy.appliedDraft(currentDraft: original, preview: preview)
    )

    XCTAssertEqual(applied.bodyMarkdown, "AI 修改后的正文")
    XCTAssertEqual(applied.summary, "AI 摘要")
    XCTAssertEqual(applied.targetWordCount, 1_200)
    XCTAssertEqual(applied.generalDraftFolderName, "新文件夹")
    XCTAssertEqual(applied.scope, original.scope)
    XCTAssertEqual(applied.id, original.id)
  }

  func testRejectsPreviewWithUnrepresentedMetadataChange() {
    let original = makeDraft()
    var proposed = original
    proposed.categories = ["不在当前差异面板显示"]
    let preview = AIChatDraftDiffPreview(
      originalDraft: original,
      updatedDraft: proposed,
      citations: []
    )

    XCTAssertNil(
      AIChatDraftDiffApplicationPolicy.appliedDraft(currentDraft: original, preview: preview)
    )
  }

  func testStagedBodyInAnotherWindowBlocksDiffBeforeStoreWrite() throws {
    let store = makeStore()
    let original = try XCTUnwrap(store.selectedDraft)
    var proposed = original
    proposed.bodyMarkdown = "AI 的旧正文修改"
    let preview = AIChatDraftDiffPreview(
      originalDraft: original,
      updatedDraft: proposed,
      citations: []
    )
    let buffer = store.draftBodyEditorBuffer(for: original.id)
    let staged = try XCTUnwrap(
      store.stageDraftBody(
        "另一窗口尚未提交的正文",
        for: original.id,
        baseRevision: buffer.revision
      )
    )
    XCTAssertTrue(staged.wasAccepted)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: original.id).isDirty)
    XCTAssertEqual(store.draft(for: original.id)?.bodyMarkdown, original.bodyMarkdown)

    // This is the same acceptance gate used by the inspector before it writes
    // a draft or records citation backlinks.
    let applied = AIChatDraftDiffApplicationPolicy.appliedDraft(
      in: store.ai,
      draftID: original.id,
      preview: preview
    )

    XCTAssertNil(applied)
    XCTAssertEqual(store.draft(for: original.id)?.bodyMarkdown, original.bodyMarkdown)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: original.id).bodyMarkdown,
      "另一窗口尚未提交的正文"
    )
  }

  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatDraftDiffApplication-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
  }

  private func makeDraft() -> ArticleDraft {
    ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "测试",
      slug: "test",
      bodyMarkdown: "原始正文"
    )
  }
}
