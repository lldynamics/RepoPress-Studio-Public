import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingSelectionEditPreviewTests: XCTestCase {
  func testSelectionEditPreviewExposesModelSummary() {
    let preview = AIPublishingSelectionEditPreview(
      kind: .polishSelection,
      range: NSRange(location: 0, length: 4),
      originalText: "text",
      replacementText: "polished text",
      providerName: "DeepSeek",
      model: "deepseek-v4-pro"
    )
    let legacyPreview = AIPublishingSelectionEditPreview(
      kind: .polishSelection,
      range: NSRange(location: 0, length: 4),
      originalText: "text",
      replacementText: "polished text"
    )

    XCTAssertEqual(preview.modelSummary, "DeepSeek · deepseek-v4-pro")
    XCTAssertNil(legacyPreview.modelSummary)
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
}
