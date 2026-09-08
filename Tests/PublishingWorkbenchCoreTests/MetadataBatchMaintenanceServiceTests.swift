import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class MetadataBatchMaintenanceServiceTests: XCTestCase {
  private let service = MetadataBatchMaintenanceService()

  func testRecoveryCoverageRequiresEveryArticleAndCountsRetainedSnapshotsAtCapacity() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let drafts = (0...DraftLifecycleService.maximumTotalVersions).map {
      ArticleDraft(siteProfileID: store.activeProfileID, title: "Article \($0)")
    }
    store.setDrafts(drafts)
    XCTAssertNil(store.prepareRetainedBatchRecoveryVersions(for: Set(drafts.map(\.id))))
    XCTAssertTrue(store.draftVersions.isEmpty)
    let supported = Array(drafts.prefix(DraftLifecycleService.maximumTotalVersions))
    store.setDrafts(supported)
    XCTAssertEqual(
      store.prepareRetainedBatchRecoveryVersions(for: Set(supported.map(\.id))), supported.count)
    XCTAssertEqual(
      BatchRecoveryCoverage.count(drafts: supported, versions: store.draftVersions), supported.count
    )
  }

  func testRenameToExistingValueMergesAndDeduplicatesOnlyMatchingArticles() {
    let profileID = UUID()
    let matching = ArticleDraft(siteProfileID: profileID, title: "匹配", tags: ["旧标签", "保留", "新标签"])
    let untouched = ArticleDraft(siteProfileID: profileID, title: "不匹配", tags: ["保留"])

    let plan = service.plan(
      drafts: [matching, untouched],
      field: .tags,
      operation: .rename(source: "旧标签", destination: "新标签")
    )

    XCTAssertEqual(plan.applicablePreviews.map(\.documentID), [matching.id])
    XCTAssertEqual(plan.applicablePreviews.first?.originalValues, ["旧标签", "保留", "新标签"])
    XCTAssertEqual(plan.applicablePreviews.first?.proposedValues, ["新标签", "保留"])
  }

  func testAddAndRemoveNormalizeInputAndPreserveOrder() {
    XCTAssertEqual(
      service.applying(.add("新闻，新闻, 推荐"), to: ["现有"]),
      ["现有", "新闻", "推荐"]
    )
    XCTAssertEqual(
      service.applying(.remove("新闻"), to: ["新闻", "保留", "新闻"]),
      ["保留"]
    )
  }

  func testPlanCapturesOnlyRequestedField() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "文章",
      tags: ["标签"],
      categories: ["旧分类"],
      bodyMarkdown: "正文不得进入计划"
    )
    let plan = service.plan(
      drafts: [draft],
      field: .categories,
      operation: .rename(source: "旧分类", destination: "新分类")
    )

    XCTAssertEqual(plan.previews.single?.originalValues, ["旧分类"])
    XCTAssertEqual(plan.previews.single?.proposedValues, ["新分类"])
  }

  func testStoreRejectsEntireBatchWhenOneFieldBaselineConflicts() throws {
    let persistenceURL = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    var first = try XCTUnwrap(store.selectedDraft)
    first.tags = ["旧标签"]
    store.updateDraft(first)
    store.createDraft()
    var second = try XCTUnwrap(store.selectedDraft)
    second.tags = ["旧标签"]
    store.updateDraft(second)
    XCTAssertTrue(store.flushPendingChanges())

    let plan = service.plan(
      drafts: [first, second],
      field: .tags,
      operation: .rename(source: "旧标签", destination: "新标签")
    )
    second.tags = ["已在别处修改"]
    store.updateDraft(second)
    XCTAssertTrue(store.flushPendingChanges())
    let versionsBefore = store.draftVersions

    let outcome = store.applyMetadataBatchMaintenance(
      plan,
      selectedDraftIDs: Set([first.id, second.id])
    )

    XCTAssertEqual(outcome, .conflicts([second.id]))
    XCTAssertEqual(store.draft(for: first.id)?.tags, ["旧标签"])
    XCTAssertEqual(store.draft(for: second.id)?.tags, ["已在别处修改"])
    XCTAssertEqual(store.draftVersions, versionsBefore)
  }

  func testStoreDoesNotApplyMetadataWhenPreflightSaveFails() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MetadataBatchMaintenanceBlocked-\(UUID().uuidString)", isDirectory: true)
    let blockingParentURL = rootURL.appendingPathComponent("not-a-directory")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data("block".utf8).write(to: blockingParentURL)
    let persistenceURL = blockingParentURL.appendingPathComponent("workbench.json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.tags = ["原标签"]
    store.updateDraft(draft)
    let plan = service.plan(
      drafts: [draft],
      field: .tags,
      operation: .add("新标签")
    )
    let versionsBefore = store.draftVersions

    let outcome = store.applyMetadataBatchMaintenance(plan, selectedDraftIDs: [draft.id])

    XCTAssertEqual(outcome, .preflightPersistenceFailed)
    XCTAssertEqual(store.draft(for: draft.id)?.tags, ["原标签"])
    XCTAssertEqual(store.draftVersions, versionsBefore)
  }

  func testStoreSuccessPreservesBodyAndUnmanagedFrontMatterSource() throws {
    let persistenceURL = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    var draft = try XCTUnwrap(store.selectedDraft)
    let sourceBody = "---\ncustom_front_matter: keep-me\n---\n\n正文保持原样"
    draft.tags = ["旧标签"]
    draft.bodyMarkdown = sourceBody
    draft.authors = ["作者保持原样"]
    store.updateDraft(draft)
    XCTAssertTrue(store.flushPendingChanges())
    let baseline = try XCTUnwrap(store.draft(for: draft.id))
    let plan = service.plan(
      drafts: [baseline],
      field: .tags,
      operation: .rename(source: "旧标签", destination: "新标签")
    )

    let outcome = store.applyMetadataBatchMaintenance(plan, selectedDraftIDs: [baseline.id])
    let updated = try XCTUnwrap(store.draft(for: baseline.id))

    guard case .applied(changedCount: 1, versionCount: _) = outcome else {
      return XCTFail("Expected a successful metadata batch, got \(outcome)")
    }
    XCTAssertEqual(updated.tags, ["新标签"])
    XCTAssertEqual(updated.bodyMarkdown, sourceBody)
    XCTAssertEqual(updated.authors, ["作者保持原样"])
    XCTAssertEqual(updated.repositoryBinding, baseline.repositoryBinding)
  }

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MetadataBatchMaintenanceTests-\(UUID().uuidString)", isDirectory: true
      )
      .appendingPathComponent("workbench.json")
  }
}

extension Array {
  fileprivate var single: Element? { count == 1 ? first : nil }
}
