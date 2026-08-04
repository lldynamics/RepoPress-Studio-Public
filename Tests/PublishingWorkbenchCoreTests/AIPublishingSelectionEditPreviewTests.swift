import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingSelectionEditPreviewTests: XCTestCase {
  func testSelectionEditPreviewExposesModelSummary() {
    let draftID = UUID()
    let citation = KnowledgeCitation(
      id: "preview-citation",
      documentID: UUID(),
      chunkID: UUID(),
      title: "本地资料",
      excerpt: "引用片段"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draftID,
      sourceBodyMarkdown: "text",
      kind: .polishSelection,
      range: NSRange(location: 0, length: 4),
      originalText: "text",
      replacementText: "polished text",
      providerName: "DeepSeek",
      model: "deepseek-v4-pro",
      knowledgeCitations: [citation]
    )
    let legacyPreview = AIPublishingSelectionEditPreview(
      draftID: draftID,
      sourceBodyMarkdown: "text",
      kind: .polishSelection,
      range: NSRange(location: 0, length: 4),
      originalText: "text",
      replacementText: "polished text"
    )

    XCTAssertEqual(preview.modelSummary, "DeepSeek · deepseek-v4-pro")
    XCTAssertEqual(preview.knowledgeCitations, [citation])
    XCTAssertNil(legacyPreview.modelSummary)
    XCTAssertTrue(legacyPreview.knowledgeCitations.isEmpty)
  }

  func testApplySelectionEditPreviewReplacesOriginalRange() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview",
      slug: "preview",
      bodyMarkdown: "Before selected text after"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draft.id,
      sourceBodyMarkdown: draft.bodyMarkdown,
      kind: .polishSelection,
      range: NSRange(location: 7, length: 13),
      originalText: "selected text",
      replacementText: "polished text"
    )

    let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)

    XCTAssertEqual(updated.bodyMarkdown, "Before polished text after")
  }

  func testApplySelectionEditPreviewInsertsAfterOriginalRange() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview",
      slug: "preview",
      bodyMarkdown: "Before selected text\nAfter"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draft.id,
      sourceBodyMarkdown: draft.bodyMarkdown,
      kind: .continueAfterSelection,
      range: NSRange(location: 7, length: 13),
      originalText: "selected text",
      replacementText: "continued paragraph",
      application: .insertAfterRange
    )

    let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)

    XCTAssertEqual(updated.bodyMarkdown, "Before selected text\n\ncontinued paragraph\nAfter")
  }

  func testApplySelectionEditPreviewInsertsAtCollapsedRange() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview",
      slug: "preview",
      bodyMarkdown: "After"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draft.id,
      sourceBodyMarkdown: draft.bodyMarkdown,
      kind: .continueAfterSelection,
      range: NSRange(location: 0, length: 0),
      originalText: "",
      replacementText: "Intro",
      application: .insertAtRange
    )

    let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)

    XCTAssertEqual(updated.bodyMarkdown, "Intro\nAfter")
  }

  func testApplySelectionEditPreviewRejectsChangedOriginalText() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview",
      slug: "preview",
      bodyMarkdown: "Before changed text after"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draft.id,
      sourceBodyMarkdown: draft.bodyMarkdown,
      kind: .polishSelection,
      range: NSRange(location: 7, length: 13),
      originalText: "selected text",
      replacementText: "polished text"
    )

    XCTAssertThrowsError(
      try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)
    ) { error in
      XCTAssertEqual(error as? AIPublishingSelectionEditPreviewApplyError, .originalTextChanged)
    }
  }

  func testApplySelectionEditPreviewRejectsEmptyReplacement() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview",
      slug: "preview",
      bodyMarkdown: "Before selected text after"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draft.id,
      sourceBodyMarkdown: draft.bodyMarkdown,
      kind: .polishSelection,
      range: NSRange(location: 7, length: 13),
      originalText: "selected text",
      replacementText: " \n "
    )

    XCTAssertThrowsError(
      try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)
    ) { error in
      XCTAssertEqual(error as? AIPublishingSelectionEditPreviewApplyError, .emptyReplacement)
    }
  }

  func testApplySelectionEditPreviewRejectsAnotherDraft() {
    let profile = SiteProfile.defaultProfile
    let sourceDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: "Original"
    )
    let currentDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Current",
      slug: "current",
      bodyMarkdown: "Original"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: sourceDraft.id,
      sourceBodyMarkdown: sourceDraft.bodyMarkdown,
      kind: .continueArticle,
      range: NSRange(location: 8, length: 0),
      originalText: "",
      replacementText: "More",
      application: .insertAtRange
    )

    XCTAssertThrowsError(
      try AIPublishingSelectionEditPreviewService.apply(preview, to: currentDraft)
    ) { error in
      XCTAssertEqual(error as? AIPublishingSelectionEditPreviewApplyError, .draftChanged)
    }
  }

  func testApplySelectionEditPreviewRejectsChangedBodyAtCollapsedRange() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview",
      slug: "preview",
      bodyMarkdown: "Original"
    )
    let preview = AIPublishingSelectionEditPreview(
      draftID: draft.id,
      sourceBodyMarkdown: draft.bodyMarkdown,
      kind: .continueArticle,
      range: NSRange(location: 8, length: 0),
      originalText: "",
      replacementText: "More",
      application: .insertAtRange
    )
    draft.bodyMarkdown = "Changed body"

    XCTAssertThrowsError(
      try AIPublishingSelectionEditPreviewService.apply(preview, to: draft)
    ) { error in
      XCTAssertEqual(error as? AIPublishingSelectionEditPreviewApplyError, .sourceBodyChanged)
    }
  }
}
