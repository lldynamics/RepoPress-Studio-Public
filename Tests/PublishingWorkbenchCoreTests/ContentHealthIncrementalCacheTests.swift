import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ContentHealthIncrementalCacheTests: XCTestCase {
  func testUnchangedDraftsHitAndOnlyChangedDraftMisses() {
    let profile = SiteProfile.defaultProfile
    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: String(repeating: "First body. ", count: 12)
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: String(repeating: "Second body. ", count: 12)
    )
    let cache = ContentHealthReportCache()
    let service = ContentHealthReportService(cache: cache)

    _ = service.report(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    XCTAssertEqual(service.cacheStatistics.missCount, 2)
    XCTAssertEqual(service.cacheStatistics.hitCount, 0)
    XCTAssertEqual(service.cacheStatistics.entryCount, 2)

    _ = service.report(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    XCTAssertEqual(service.cacheStatistics.missCount, 2)
    XCTAssertEqual(service.cacheStatistics.hitCount, 2)

    var changedDraft = firstDraft
    changedDraft.bodyMarkdown += "A changed paragraph."
    _ = service.report(
      drafts: [changedDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    XCTAssertEqual(service.cacheStatistics.missCount, 3)
    XCTAssertEqual(service.cacheStatistics.hitCount, 3)
    XCTAssertEqual(service.cacheStatistics.entryCount, 2)
  }

  func testSharedCacheDoesNotCrossServiceNamespaces() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Namespace",
      slug: "namespace",
      bodyMarkdown: String(repeating: "Namespace body. ", count: 12)
    )
    let cache = ContentHealthReportCache()
    let firstService = ContentHealthReportService(cache: cache)
    let secondService = ContentHealthReportService(cache: cache)

    _ = firstService.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    _ = secondService.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])

    // Statistics belong to the explicitly shared cache, so both namespace
    // misses are visible from either service while no cross-service hit occurs.
    XCTAssertEqual(firstService.cacheStatistics.missCount, 2)
    XCTAssertEqual(secondService.cacheStatistics.missCount, 2)
    XCTAssertEqual(secondService.cacheStatistics.hitCount, 0)
  }

  func testDuplicateStateChangeInvalidatesAffectedArticles() {
    let profile = SiteProfile.defaultProfile
    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: String(repeating: "First body. ", count: 12)
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: String(repeating: "Second body. ", count: 12)
    )
    let service = ContentHealthReportService(cache: ContentHealthReportCache())

    _ = service.report(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )

    var duplicateDraft = secondDraft
    duplicateDraft.title = firstDraft.title
    _ = service.report(
      drafts: [firstDraft, duplicateDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )

    XCTAssertEqual(service.cacheStatistics.missCount, 4)
    XCTAssertEqual(service.cacheStatistics.hitCount, 0)
  }

  func testProfileAndPresentationChangesInvalidateExpectedArticles() {
    let profile = SiteProfile.defaultProfile
    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "First",
      bodyMarkdown: String(repeating: "First body. ", count: 12)
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: String(repeating: "Second body. ", count: 12)
    )
    let service = ContentHealthReportService(cache: ContentHealthReportCache())

    _ = service.report(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )

    let presentation = [
      firstDraft.id: ContentHealthDraftPresentation(
        title: "Renamed in presentation",
        markdownPath: profile.markdownPath(for: firstDraft)
      ),
    ]
    let presentationReport = service.report(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: presentation
    )
    XCTAssertEqual(service.cacheStatistics.missCount, 3)
    XCTAssertEqual(service.cacheStatistics.hitCount, 1)
    XCTAssertEqual(presentationReport.draftSummaries.first?.draftTitle, "Renamed in presentation")

    var changedProfile = profile
    changedProfile.slugValidationRule = .disabled
    _ = service.report(
      drafts: [firstDraft, secondDraft],
      profile: changedProfile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    XCTAssertEqual(service.cacheStatistics.missCount, 5)
    XCTAssertEqual(service.cacheStatistics.hitCount, 1)
  }

  func testResourceMetadataChangeInvalidatesArticle() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ContentHealthIncrementalCache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("hero.jpg")
    try Data(repeating: 1, count: 4_096).write(to: sourceURL)
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "hero.jpg",
      relativePublishPath: "/images/hero.jpg",
      repositoryPath: "static/images/hero.jpg",
      altText: "Hero",
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Image",
      slug: "image",
      bodyMarkdown: String(repeating: "Image body. ", count: 12),
      attachments: [attachment]
    )
    let service = ContentHealthReportService(cache: ContentHealthReportCache())

    _ = service.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    _ = service.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertEqual(service.cacheStatistics.missCount, 1)
    XCTAssertEqual(service.cacheStatistics.hitCount, 1)

    try Data(repeating: 2, count: 8_192).write(to: sourceURL)
    _ = service.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertEqual(service.cacheStatistics.missCount, 2)
    XCTAssertEqual(service.cacheStatistics.hitCount, 1)
  }

  func testUnreadableResourceFallsBackToFullRecomputation() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "missing.jpg",
      relativePublishPath: "/images/missing.jpg",
      repositoryPath: "static/images/missing.jpg",
      altText: "Missing",
      sourceFilePath: "/definitely/missing/content-health.jpg"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Missing image",
      slug: "missing-image",
      bodyMarkdown: String(repeating: "Missing image body. ", count: 12),
      attachments: [attachment]
    )
    let service = ContentHealthReportService(cache: ContentHealthReportCache())

    _ = service.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    _ = service.report(drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])

    XCTAssertEqual(service.cacheStatistics.entryCount, 0)
    XCTAssertEqual(service.cacheStatistics.missCount, 2)
    XCTAssertEqual(service.cacheStatistics.uncacheableCount, 2)
  }

  func testDeletedDraftIsPrunedAndAsyncReportReusesSyncSummary() async throws {
    let profile = SiteProfile.defaultProfile
    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: String(repeating: "First body. ", count: 12)
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: String(repeating: "Second body. ", count: 12)
    )
    let service = ContentHealthReportService(cache: ContentHealthReportCache())
    let synchronous = service.report(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    let asynchronous = try await service.reportAsync(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )

    XCTAssertEqual(synchronous.draftSummaries, asynchronous.draftSummaries)
    XCTAssertEqual(service.cacheStatistics.hitCount, 2)

    _ = service.report(
      drafts: [firstDraft],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    XCTAssertEqual(service.cacheStatistics.entryCount, 1)
  }
}
