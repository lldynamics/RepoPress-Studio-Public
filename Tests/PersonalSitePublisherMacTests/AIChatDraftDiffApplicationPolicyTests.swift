import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

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

  private func makeDraft() -> ArticleDraft {
    ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "测试",
      slug: "test",
      bodyMarkdown: "原始正文"
    )
  }
}
