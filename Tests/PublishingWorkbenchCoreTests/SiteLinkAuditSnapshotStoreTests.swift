import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class SiteLinkAuditSnapshotStoreTests: XCTestCase {
  func testTaskQueueRefreshesBrokenLinkAfterBodyChangeDespiteWordCountBackfill() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      safeMode: true
    )
    let profile = store.activeProfile
    let target = ArticleDraft(
      siteProfileID: profile.id,
      title: "Target",
      slug: "target",
      bodyMarkdown: "Target body"
    )
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: "[Target](/target/)"
    )
    store.setDrafts([source, target])

    _ = store.draftTaskQueueStates(for: store.drafts)
    if let task = store.siteLinkAuditRefreshTask { _ = await task.value }
    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, 1)

    _ = store.draftTaskQueueStates(for: store.drafts)
    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, 1)

    var changed = try XCTUnwrap(store.draft(for: source.id))
    changed.bodyMarkdown = "[Missing](/missing/)"
    store.updateDraft(changed)

    _ = store.draftTaskQueueStates(for: store.drafts)
    // The queued report is already evaluating the changed Markdown. Simulate
    // the real asynchronous word-count completion before it returns: this
    // mutates the draft collection but not any link-audit input.
    store.publishingStore.updateDraftWordCount(
      1,
      for: source.id,
      matching: changed.bodyMarkdown,
      store: store
    )
    if let task = store.siteLinkAuditRefreshTask { _ = await task.value }
    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, 2)
    let report = try XCTUnwrap(
      store.cachedSiteLinkAuditReport(drafts: store.drafts, profile: profile)
    )
    XCTAssertEqual(
      report.references.first(where: { $0.target == "/missing/" })?.resolution,
      .brokenInternal
    )
  }

  func testSlugMetadataChangeInvalidatesSiteLinkAuditSnapshot() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      safeMode: true
    )
    let profile = store.activeProfile
    let target = ArticleDraft(
      siteProfileID: profile.id,
      title: "Target",
      slug: "target"
    )
    let originalPath = SiteArticleURLResolver().relativeWebPath(
      from: profile.markdownPath(for: target), profile: profile, permalink: target.permalink)
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: "[Target](\(originalPath))"
    )
    store.setDrafts([source, target])

    _ = store.draftTaskQueueStates(for: store.drafts)
    if let task = store.siteLinkAuditRefreshTask { _ = await task.value }

    XCTAssertEqual(
      store.cachedSiteLinkAuditReport(drafts: store.drafts, profile: profile)?
        .references.first?.resolution,
      .validInternal
    )

    var renamedTarget = try XCTUnwrap(store.draft(for: target.id))
    renamedTarget.slug = "renamed-target"
    store.updateDraft(renamedTarget)

    _ = store.draftTaskQueueStates(for: store.drafts)
    if let task = store.siteLinkAuditRefreshTask { _ = await task.value }

    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, 2)
    let report = try XCTUnwrap(
      store.cachedSiteLinkAuditReport(drafts: store.drafts, profile: profile)
    )
    XCTAssertEqual(
      report.references.first(where: { $0.target == originalPath })?.resolution,
      .pendingSlugRedirect
    )
  }

  func testInvalidatedTaskCannotReplaceNewerSiteLinkAuditSnapshot() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      safeMode: true
    )
    let profile = store.activeProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: "[Missing](/missing/)"
    )
    store.setDrafts([draft])
    let staleKey = store.siteLinkAuditKey(drafts: store.drafts, profile: profile)
    let staleReport = SiteLinkAuditService().report(drafts: store.drafts, profile: profile)

    store.invalidateSiteLinkAuditSnapshot()
    let currentKey = store.siteLinkAuditKey(drafts: store.drafts, profile: profile)
    XCTAssertNotEqual(staleKey, currentKey)

    store.replaceSiteLinkAuditSnapshotIfCurrent(
      staleReport,
      key: staleKey,
      drafts: store.drafts,
      profile: profile
    )
    XCTAssertNil(store.cachedSiteLinkAuditReport(drafts: store.drafts, profile: profile))

    let currentReport = SiteLinkAuditService().report(drafts: store.drafts, profile: profile)
    store.replaceSiteLinkAuditSnapshotIfCurrent(
      currentReport,
      key: currentKey,
      drafts: store.drafts,
      profile: profile
    )
    XCTAssertEqual(
      store.cachedSiteLinkAuditReport(drafts: store.drafts, profile: profile)?.items,
      currentReport.items
    )
  }

  func testConcurrentConsumersCoalesceOneSiteReportReplacement() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      safeMode: true
    )
    let profile = store.activeProfile
    let drafts = (0..<80).map { index in
      ArticleDraft(
        siteProfileID: profile.id,
        title: "Draft \(index)",
        slug: "draft-\(index)",
        bodyMarkdown: index == 0 ? "[Target](/draft-79/)" : "Body \(index)"
      )
    }
    store.setDrafts(drafts)

    let first = Task {
      try await store.localSiteLinkAuditReportAsync(
        drafts: drafts,
        profile: profile
      )
    }
    await Task.yield()
    let second = Task {
      try await store.localSiteLinkAuditReportAsync(
        drafts: drafts,
        profile: profile
      )
    }

    let firstReport = try await first.value
    let secondReport = try await second.value
    XCTAssertEqual(firstReport.items, secondReport.items)
    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, 1)
  }

  func testStaleDraftSnapshotCannotPopulateCurrentLinkAuditCache() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      safeMode: true
    )
    let profile = store.activeProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: "Body"
    )
    store.setDrafts([source])
    let staleDrafts = store.drafts

    var changed = try XCTUnwrap(store.draft(for: source.id))
    changed.bodyMarkdown = "[Missing](/missing/)"
    store.updateDraft(changed)

    do {
      _ = try await store.localSiteLinkAuditReportAsync(drafts: staleDrafts, profile: profile)
      XCTFail("An obsolete draft snapshot must not enter the current cache")
    } catch is CancellationError {
      // The caller must retry with a current snapshot.
    }

    let report = try await store.localSiteLinkAuditReportAsync(
      drafts: store.drafts,
      profile: profile
    )
    XCTAssertEqual(report.items.map(\.target), ["/missing/"])
    XCTAssertEqual(
      store.cachedSiteLinkAuditReport(drafts: store.drafts, profile: profile)?.items.map(\.target),
      ["/missing/"]
    )
  }

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("site-link-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")
  }
}
