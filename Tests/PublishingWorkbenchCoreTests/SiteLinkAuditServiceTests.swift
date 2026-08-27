import XCTest
@testable import PublishingWorkbenchCore

final class SiteLinkAuditServiceTests: XCTestCase {
  func testResolvesRelativeMarkdownRoutesAliasesAndPendingSlugRoutes() throws {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .vitePress
    profile.contentRoot = "docs"
    profile.markdownPathPattern = "docs/{slug}.md"
    let target = ArticleDraft(
      siteProfileID: profile.id,
      title: "Target Note",
      slug: "target",
      aliases: ["/kept-alias/"],
      pendingSlugRedirectPaths: ["/old-target/"]
    )
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "guide/source",
      bodyMarkdown: "[relative](../target.md) [alias](/kept-alias/) [old](/old-target/)"
    )

    let report = SiteLinkAuditService().report(drafts: [source, target], profile: profile)

    XCTAssertEqual(report.references.count, 3)
    XCTAssertEqual(report.references[0].resolvedDraftID, target.id)
    XCTAssertEqual(report.references[0].resolution, .validInternal)
    XCTAssertEqual(report.references[1].resolution, .validInternal)
    XCTAssertEqual(report.references[2].resolution, .pendingSlugRedirect)
    XCTAssertEqual(report.items.filter { $0.kind == .slugRedirectReference }.count, 1)
  }

  func testScansWikiAutolinksAndBareURLsWhileIgnoringCodeAndImages() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let target = ArticleDraft(
      siteProfileID: profile.id,
      title: "Wiki Target",
      slug: "wiki-target"
    )
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: """
      [[Wiki Target#part|label]]
      <https://example.com/docs>
      https://example.org/raw
      ![image](/missing.png)
      `[[Missing Inline Code]]`
      ```md
      [missing](/inside-code/)
      ```
      """
    )

    let report = SiteLinkAuditService().report(drafts: [source, target], profile: profile)

    XCTAssertEqual(report.references.count, 3)
    XCTAssertEqual(report.references.first?.syntax, .wiki)
    XCTAssertEqual(report.references.first?.resolvedDraftID, target.id)
    XCTAssertEqual(report.references.filter { $0.resolution == .external }.count, 2)
    XCTAssertFalse(report.items.contains { $0.target.contains("inside-code") })
    XCTAssertFalse(report.items.contains { $0.target.contains("missing.png") })
  }

  func testDestinationRangeCoversOnlyPathAndPreservesFragment() throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let target = ArticleDraft(siteProfileID: profile.id, title: "Old", slug: "new")
    var changedTarget = target
    changedTarget.pendingSlugRedirectPaths = ["/old/"]
    let body = "Read [the old page](/old/#details) now."
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: body
    )

    let reference = try XCTUnwrap(
      SiteLinkAuditService().report(drafts: [source, changedTarget], profile: profile)
        .references.first
    )

    XCTAssertEqual((body as NSString).substring(with: reference.targetUTF16Range), "/old/")
    XCTAssertEqual(reference.target, "/old/#details")
    XCTAssertEqual(reference.resolution, .pendingSlugRedirect)
  }

  func testAsyncExternalProbeDistinguishesConfirmedDeadFromTemporaryFailure() async throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "External",
      slug: "external",
      bodyMarkdown: "[gone](https://example.com/gone) [slow](https://example.org/slow)"
    )
    let service = SiteLinkAuditService(
      externalProbe: SiteExternalLinkProbe { url in
        if url.host == "example.com" {
          return SiteExternalLinkProbeResult(url: url, statusCode: 404, finalURL: url)
        }
        return SiteExternalLinkProbeResult(url: url, failureMessage: "timeout")
      }
    )

    let report = try await service.reportAsync(drafts: [source], profile: profile)

    XCTAssertTrue(report.items.contains {
      $0.target.contains("gone") && $0.kind == .externalDead && $0.severity == .error
    })
    XCTAssertTrue(report.items.contains {
      $0.target.contains("slow") && $0.kind == .externalUnverified && $0.severity == .warning
    })
  }
}
