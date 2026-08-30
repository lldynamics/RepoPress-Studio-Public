import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class SiteLinkAuditSnapshotStoreTests: XCTestCase {
  func testTaskQueueReusesOneSiteReportUntilDraftRevisionChanges() async throws {
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
    if let task = store.siteLinkAuditRefreshTask { _ = await task.value }
    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, 2)
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

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("site-link-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")
  }
}
