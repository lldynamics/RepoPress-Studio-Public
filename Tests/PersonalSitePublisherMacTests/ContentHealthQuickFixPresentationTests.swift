import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class ContentHealthQuickFixPresentationTests: XCTestCase {
  func testMissingAltQuickFixTargetsExactAttachment() throws {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Article",
      slug: "article",
      attachments: [attachment]
    )
    let issue = PreflightIssue(
      severity: .warning,
      title: "Missing Alt",
      message: "Missing Alt",
      category: .missingMediaAlt,
      relatedValue: attachment.id.uuidString
    )

    let presentation = try XCTUnwrap(issue.contentHealthQuickFix(for: draft))

    XCTAssertEqual(presentation.kind, .generateImageAlt(attachmentID: attachment.id))
  }

  func testBrokenLinkQuickFixOnlyOffersPickerForRelativeResourceLikeTargets() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Article", slug: "article")
    let relative = PreflightIssue(
      severity: .warning,
      title: "Broken",
      message: "Broken",
      category: .brokenInternalLink,
      relatedValue: "../assets/guide.pdf"
    )
    let external = PreflightIssue(
      severity: .warning,
      title: "Broken",
      message: "Broken",
      category: .brokenInternalLink,
      relatedValue: "https://example.com/guide.pdf"
    )
    let wikiLike = PreflightIssue(
      severity: .warning,
      title: "Broken",
      message: "Broken",
      category: .brokenInternalLink,
      relatedValue: "Guide"
    )

    XCTAssertEqual(
      relative.contentHealthQuickFix(for: draft)?.kind,
      .repairRelativePath(target: "../assets/guide.pdf")
    )
    XCTAssertNil(external.contentHealthQuickFix(for: draft))
    XCTAssertNil(wikiLike.contentHealthQuickFix(for: draft))
  }
}
