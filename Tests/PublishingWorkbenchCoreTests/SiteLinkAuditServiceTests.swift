import PublishingDomainContracts
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

    XCTAssertTrue(
      report.items.contains {
        $0.target.contains("gone") && $0.kind == .externalDead && $0.severity == .error
      })
    XCTAssertTrue(
      report.items.contains {
        $0.target.contains("slow") && $0.kind == .externalUnverified && $0.severity == .warning
      })
  }
}

final class SiteUnpublishImpactServiceTests: XCTestCase {
  func testPreviewResolvesTargetAliasesAndRepeatedLinksButExcludesSelfOtherSiteAndGeneralDraft() {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .vitePress
    profile.contentRoot = "docs"
    profile.markdownPathPattern = "docs/{slug}.md"
    let target = ArticleDraft(
      siteProfileID: profile.id, title: "目标", slug: "target", aliases: ["/old-target/"],
      draft: false, bodyMarkdown: "[自身](/target/)", status: .published)
    let source = ArticleDraft(
      siteProfileID: profile.id, title: "来源", slug: "source", draft: false,
      bodyMarkdown: "[当前](/target/) [别名](/old-target/)", status: .published)
    let privateSource = ArticleDraft(
      siteProfileID: profile.id, title: "私密来源", slug: "private", draft: false, visibility: .private,
      bodyMarkdown: "[目标](/target/)", status: .published)
    let unpublishedSource = ArticleDraft(
      siteProfileID: profile.id, title: "编辑中来源", slug: "editing", bodyMarkdown: "[目标](/target/)",
      status: .draft)
    let otherSite = ArticleDraft(
      siteProfileID: UUID(), title: "其他站点", slug: "other", draft: false,
      bodyMarkdown: "[目标](/target/)", status: .published)
    let general = ArticleDraft(
      siteProfileID: profile.id, scope: .general, title: "通用草稿", slug: "general",
      bodyMarkdown: "[目标](/target/)", status: .draft)

    let preview = SiteUnpublishImpactService().preview(
      target: target,
      drafts: [target, source, privateSource, unpublishedSource, otherSite, general],
      profile: profile)

    XCTAssertEqual(preview.sourceArticleCount, 3)
    XCTAssertEqual(preview.referenceCount, 4)
    XCTAssertEqual(
      Set(preview.sources.map(\.sourceDraftID)),
      Set([source.id, privateSource.id, unpublishedSource.id])
    )
    XCTAssertEqual(Set(preview.sources.map(\.id)).count, preview.referenceCount)
  }

  func testSnapshotInvalidatesForCandidateInputChangesButIgnoresOrdering() {
    let profile = SiteProfile.defaultProfile
    let target = ArticleDraft(
      siteProfileID: profile.id, title: "目标", slug: "target", draft: false, bodyMarkdown: "# 目标",
      status: .published)
    let source = ArticleDraft(
      siteProfileID: profile.id, title: "来源", slug: "source", draft: false,
      bodyMarkdown: "[目标](/target/)", status: .published)
    let preview = SiteUnpublishImpactService().preview(
      target: target, drafts: [target, source], profile: profile)

    XCTAssertTrue(
      preview.remainsValid(target: target, sources: [source, target], profile: profile))
    var editedSource = source
    editedSource.aliases = ["/new-source/"]
    XCTAssertFalse(
      preview.remainsValid(target: target, sources: [target, editedSource], profile: profile))
    let added = ArticleDraft(siteProfileID: profile.id, title: "新增", slug: "new")
    XCTAssertFalse(
      preview.remainsValid(target: target, sources: [target, source, added], profile: profile))
    var changedProfile = profile
    changedProfile.repositoryPublishStrategy = .direct
    XCTAssertFalse(
      preview.remainsValid(target: target, sources: [target, source], profile: changedProfile))
    var movedTarget = target
    movedTarget.assignToSite(UUID())
    XCTAssertFalse(
      preview.remainsValid(target: movedTarget, sources: [movedTarget, source], profile: profile))
  }

  func testSnapshotInvalidatesWhenTargetIsRemovedOrSourceBodyChanges() {
    let profile = SiteProfile.defaultProfile
    let target = ArticleDraft(
      siteProfileID: profile.id, title: "目标", slug: "target", draft: false, bodyMarkdown: "# 目标",
      status: .published)
    let source = ArticleDraft(
      siteProfileID: profile.id, title: "来源", slug: "source", draft: false,
      bodyMarkdown: "[目标](/target/)", status: .published)
    let preview = SiteUnpublishImpactService().preview(
      target: target, drafts: [target, source], profile: profile)

    XCTAssertFalse(preview.remainsValid(target: target, sources: [source], profile: profile))
    var editedSource = source
    editedSource.bodyMarkdown += "\n变化"
    XCTAssertFalse(
      preview.remainsValid(target: target, sources: [target, editedSource], profile: profile))
  }
}
