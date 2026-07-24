import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class SiteMaintenanceBackgroundRefreshTests: XCTestCase {
  func testAsyncReportMatchesSynchronousReport() async throws {
    let profile = SiteProfile.defaultProfile
    let now = Date(timeIntervalSince1970: 1_783_267_200)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Async maintenance",
      slug: "async-maintenance",
      tags: ["Swift"],
      draft: false,
      bodyMarkdown: "Body",
      status: .published
    )
    let service = SiteMaintenanceService()

    let synchronous = service.report(
      drafts: [draft],
      profile: profile,
      releaseRecords: [],
      now: now
    )
    let asynchronous = try await service.reportAsync(
      drafts: [draft],
      profile: profile,
      releaseRecords: [],
      now: now
    )

    XCTAssertEqual(asynchronous, synchronous)
  }

  @MainActor
  func testSupersededMaintenanceRefreshIsCancelledAndCannotReplaceCurrentSnapshot() async throws {
    let tracker = MaintenanceReportInvocationTracker()
    let baseService = SiteMaintenanceService()
    let service = SiteMaintenanceService(
      asyncReportOperation: { drafts, profile, releases, operations, now in
        let title = drafts.first?.title ?? "Empty"
        try await tracker.perform(title: title)
        return baseService.report(
          drafts: drafts,
          profile: profile,
          releaseRecords: releases,
          maintenanceOperationRecords: operations,
          now: now
        )
      }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      siteMaintenanceService: service
    )
    let profile = store.activeProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      tags: ["Maintenance"],
      bodyMarkdown: "Body",
      status: .ready
    )
    store.setDrafts([draft])

    let firstRefresh = Task { @MainActor in
      await store.refreshSiteMaintenanceSnapshot(force: true)
    }
    await tracker.waitUntilStarted(title: "First")

    draft.title = "Final"
    store.setDrafts([draft])
    let finalRefresh = Task { @MainActor in
      await store.refreshSiteMaintenanceSnapshot(force: true)
    }
    await tracker.waitUntilStarted(title: "Final")

    await finalRefresh.value
    await firstRefresh.value

    let counts = await tracker.counts()
    XCTAssertEqual(counts.cancelled, 1)
    XCTAssertEqual(store.siteMaintenanceSnapshot?.report.calendarScheduleItems.first?.title, "Final")
    XCTAssertFalse(store.isSiteMaintenanceSnapshotRefreshing)
    XCTAssertFalse(store.isSiteMaintenanceSnapshotStale)
  }

  @MainActor
  func testCurrentSnapshotIsReusedAndRelatedSuggestionsUseTheIndex() async throws {
    let tracker = MaintenanceReportInvocationTracker()
    let baseService = SiteMaintenanceService()
    let service = SiteMaintenanceService(
      asyncReportOperation: { drafts, profile, releases, operations, now in
        let title = drafts.first?.title ?? "Empty"
        try await tracker.perform(title: title)
        return baseService.report(
          drafts: drafts,
          profile: profile,
          releaseRecords: releases,
          maintenanceOperationRecords: operations,
          now: now
        )
      }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      siteMaintenanceService: service
    )
    let profile = store.activeProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Source",
      slug: "source",
      tags: ["Shared"],
      draft: false,
      bodyMarkdown: "No link yet.",
      status: .published
    )
    let target = ArticleDraft(
      siteProfileID: profile.id,
      title: "Target",
      slug: "target",
      tags: ["Shared"],
      draft: false,
      bodyMarkdown: "Target body.",
      status: .published
    )
    store.setDrafts([source, target])

    await store.refreshSiteMaintenanceSnapshot(force: true)
    await store.refreshSiteMaintenanceSnapshot()

    var counts = await tracker.counts()
    XCTAssertEqual(counts.completed, 1)
    XCTAssertEqual(
      store.relatedArticleSuggestions(for: source).map(\.targetDraftID),
      [target.id]
    )
    counts = await tracker.counts()
    XCTAssertEqual(counts.completed, 1)
  }

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("site-maintenance-background-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")
  }
}

private actor MaintenanceReportInvocationTracker {
  private var startedTitles = Set<String>()
  private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private(set) var cancellationCount = 0
  private(set) var completedCount = 0

  func perform(title: String) async throws {
    startedTitles.insert(title)
    startWaiters.removeValue(forKey: title)?.forEach { $0.resume() }
    do {
      if title == "First" {
        try await Task.sleep(for: .seconds(10))
      } else {
        try await Task.sleep(for: .milliseconds(10))
      }
      completedCount += 1
    } catch {
      cancellationCount += 1
      throw error
    }
  }

  func waitUntilStarted(title: String) async {
    if startedTitles.contains(title) { return }
    await withCheckedContinuation { continuation in
      startWaiters[title, default: []].append(continuation)
    }
  }

  func counts() -> (cancelled: Int, completed: Int) {
    (cancellationCount, completedCount)
  }
}
