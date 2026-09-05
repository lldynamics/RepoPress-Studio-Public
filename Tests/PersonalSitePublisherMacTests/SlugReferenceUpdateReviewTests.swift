import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class SlugReferenceUpdateReviewTests: XCTestCase {
  func testPreviewShowsExactUnicodeTokenRangesAndWikiReplacement() throws {
    let profileID = UUID()
    let targetID = UUID()
    let body = "中文 [link](/old/#section) and [[old#part]]"
    let source = ArticleDraft(
      siteProfileID: profileID, title: "来源", slug: "source",
      bodyMarkdown: body)
    let text = body as NSString
    let markdown = SiteLinkReference(
      sourceDraftID: source.id, sourceTitle: source.title,
      anchorText: "link", target: "/old/#section", syntax: .markdown,
      targetUTF16Range: text.range(of: "/old/"), resolution: .pendingSlugRedirect)
    let wiki = SiteLinkReference(
      sourceDraftID: source.id, sourceTitle: source.title,
      anchorText: "", target: "old#part", syntax: .wiki,
      targetUTF16Range: text.range(of: "old", options: .backwards), resolution: .pendingSlugRedirect
    )
    let impact = SlugChangeImpact(
      targetDraftID: targetID, targetTitle: "Target",
      oldRoutes: ["/old/"], newRoute: "/new/", references: [markdown, wiki],
      conflictingAliasRoutes: [])

    let review = try XCTUnwrap(
      SlugReferenceUpdateReview(
        profileID: profileID, impact: impact,
        targetSlug: "new-slug", sources: [source.id: (source, body, "content/source.md")]))

    XCTAssertEqual(review.articles.count, 1)
    XCTAssertEqual(review.articles[0].changes.map(\.oldTarget), ["/old/", "old"])
    XCTAssertEqual(review.articles[0].changes.map(\.newTarget), ["/new/", "new-slug"])
    XCTAssertEqual(review.articles[0].path, "content/source.md")
  }

  func testPreviewRefusesReferencesMissingTheirSourceDocument() {
    let impact = SlugChangeImpact(
      targetDraftID: UUID(), targetTitle: "Target",
      oldRoutes: ["/old/"], newRoute: "/new/",
      references: [
        SiteLinkReference(
          sourceDraftID: UUID(), sourceTitle: "Missing", anchorText: "",
          target: "/old/", syntax: .markdown, targetUTF16Range: NSRange(location: 0, length: 5),
          resolution: .pendingSlugRedirect)
      ], conflictingAliasRoutes: [])
    XCTAssertNil(
      SlugReferenceUpdateReview(
        profileID: UUID(), impact: impact,
        targetSlug: "new", sources: [:]))
  }
}
