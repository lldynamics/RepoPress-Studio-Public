import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchProjectFileSaveRecoveryTests: XCTestCase {
  func testFailuresGroupByProfileRootAndReasonAndListEachPathOnce() async throws {
    let fixture = try await makeFixture(prefix: "save-recovery-groups")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }

    let first = try await fixture.addDraft(slug: "first", body: "第一篇")
    let second = try await fixture.addDraft(slug: "second", body: "第二篇")
    let missingRoot = fixture.baseURL.appendingPathComponent("missing-repository")
    fixture.store.updateActiveProfile { $0.localRepositoryRootPath = missingRoot.path }
    for (draftID, body) in [(first.id, "待写入一"), (second.id, "待写入二")] {
      var draft = try XCTUnwrap(fixture.store.drafts.first { $0.id == draftID })
      draft.bodyMarkdown = body
      fixture.store.updateDraft(draft)
    }
    let flushResult = fixture.store.flushPendingChanges()
    XCTAssertFalse(flushResult)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    let groups = fixture.store.siteDraftFileSaveFailureGroups
    XCTAssertEqual(groups.count, 1)
    let group = try XCTUnwrap(groups.first)
    XCTAssertEqual(group.failures.count, 2)
    XCTAssertTrue(group.summary.contains("2 篇草稿"))
    XCTAssertEqual(group.summary.components(separatedBy: missingRoot.path).count, 2)
    XCTAssertFalse(group.summary.contains("content/posts/"))
    XCTAssertNil(fixture.store.persistenceStatus.lastSaveError)
    XCTAssertNotNil(fixture.store.persistenceStatus.siteDraftFileSaveFailureSummary)
    XCTAssertEqual(group.details.components(separatedBy: "content/posts/").count, 3)
    XCTAssertTrue(group.details.contains("first.md"))
    XCTAssertTrue(group.details.contains("second.md"))
    await fixture.store.waitForPendingSave()
  }

  func testExternalConflictSurvivesRetryUntilTrustedDiskBaselineIsRestored() async throws {
    let fixture = try await makeFixture(prefix: "save-recovery-external")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "conflict", body: "初始")
    var changed = draft
    changed.bodyMarkdown = "应用内的新正文"
    fixture.store.updateDraft(changed)
    let external = "外部软件写入的可信内容"
    try external.write(to: fixture.url(for: draft), atomically: true, encoding: .utf8)

    let firstResult = fixture.store.flushPendingChanges()
    XCTAssertFalse(firstResult)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let retryResult = await fixture.store.retryPendingProjectFileWrites()
    XCTAssertFalse(retryResult)
    XCTAssertEqual(try String(contentsOf: fixture.url(for: draft), encoding: .utf8), external)

    try XCTUnwrap(fixture.initialDocuments[draft.id]).write(
      to: fixture.url(for: draft), atomically: true, encoding: .utf8)
    let restoredResult = await fixture.store.retryPendingProjectFileWrites()
    XCTAssertTrue(restoredResult)
    XCTAssertNil(fixture.store.siteDraftFileSaveFailureSummary)
    XCTAssertTrue(
      try String(contentsOf: fixture.url(for: draft), encoding: .utf8).contains("应用内的新正文"))
    await fixture.store.waitForPendingSave()
  }

  func testChangingRootRejectsNonGitDirectoryAndKeepsOriginalRoot() async throws {
    let fixture = try await makeFixture(prefix: "save-recovery-root-validation")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let profileID = fixture.store.activeProfileID
    let originalRoot = fixture.store.activeProfile.localRepositoryRootURL
    let invalidRoot = fixture.baseURL.appendingPathComponent("plain-directory")
    try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try fixture.store.changeRepositoryRootForSaveRecovery(profileID: profileID, to: invalidRoot))
    XCTAssertEqual(
      fixture.store.profiles.first { $0.id == profileID }?.localRepositoryRootURL, originalRoot)
    await fixture.store.waitForPendingSave()
  }

  func testRetryTargetsFailedProfileAndNewRootWithoutChangingActiveSite() async throws {
    let fixture = try await makeFixture(prefix: "save-recovery-profile")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let firstProfileID = fixture.store.activeProfileID
    let draft = try await fixture.addDraft(slug: "moved", body: "旧正文")
    let oldRoot = fixture.repositoryURL
    let oldFile = fixture.url(for: draft)
    fixture.store.updateActiveProfile {
      $0.localRepositoryRootPath = fixture.baseURL.appendingPathComponent("gone").path
    }
    var failedDraft = draft
    failedDraft.bodyMarkdown = "迁移后的正文"
    fixture.store.updateDraft(failedDraft)
    let failedResult = fixture.store.flushPendingChanges()
    XCTAssertFalse(failedResult)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    let secondProfile = fixture.store.createProfile(named: "另一个站点")
    let activeID = fixture.store.activeProfileID
    let newRoot = fixture.baseURL.appendingPathComponent("new-repository")
    try copyRepository(from: oldRoot, to: newRoot)
    try fixture.store.changeRepositoryRootForSaveRecovery(profileID: firstProfileID, to: newRoot)
    let retryResult = await fixture.store.retryPendingProjectFileWrites(profileID: firstProfileID)
    XCTAssertTrue(retryResult)
    XCTAssertEqual(fixture.store.activeProfileID, activeID)
    XCTAssertEqual(fixture.store.activeProfileID, secondProfile.id)
    XCTAssertEqual(
      try String(contentsOf: oldFile, encoding: .utf8), fixture.initialDocuments[draft.id])
    XCTAssertTrue(
      try String(
        contentsOf: newRoot.appendingPathComponent(try XCTUnwrap(draft.repositoryPath)),
        encoding: .utf8
      ).contains("迁移后的正文"))
    await fixture.store.waitForPendingSave()
  }

  func testUnboundFirstWriteCanRetryAfterRepositoryBecomesAvailable() async throws {
    let fixture = try await makeFixture(prefix: "save-recovery-unbound")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    fixture.store.updateActiveProfile {
      $0.localRepositoryRootPath = fixture.baseURL.appendingPathComponent("not-yet").path
    }
    fixture.store.createDraft()
    var draft = try XCTUnwrap(fixture.store.selectedDraft)
    draft.slug = "first-write"
    draft.title = "首次写入"
    draft.bodyMarkdown = "等待项目后的正文"
    fixture.store.updateDraft(draft)
    let failedResult = await fixture.store.writeSiteDraftToProject(draftID: draft.id)
    XCTAssertFalse(failedResult)
    XCTAssertEqual(fixture.store.siteDraftFileSaveFailureGroups.count, 1)

    try fixture.store.changeRepositoryRootForSaveRecovery(
      profileID: fixture.store.activeProfileID, to: fixture.repositoryURL)
    let retryResult = await fixture.store.retryPendingProjectFileWrites()
    XCTAssertTrue(retryResult)
    let path = fixture.repositoryURL.appendingPathComponent("content/posts/first-write.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("等待项目后的正文"))
    await fixture.store.waitForPendingSave()
  }

  @MainActor
  private final class Fixture {
    let baseURL: URL
    let repositoryURL: URL
    let store: WorkbenchStore
    var initialDocuments: [UUID: String] = [:]

    init(baseURL: URL, repositoryURL: URL, store: WorkbenchStore) {
      self.baseURL = baseURL
      self.repositoryURL = repositoryURL
      self.store = store
    }

    func url(for draft: ArticleDraft) -> URL {
      repositoryURL.appendingPathComponent(draft.repositoryPath ?? "")
    }

    func addDraft(slug: String, body: String) async throws -> ArticleDraft {
      store.createDraft()
      var draft = try XCTUnwrap(store.selectedDraft)
      draft.slug = slug
      draft.title = slug
      draft.bodyMarkdown = body
      store.updateDraft(draft)
      let didWrite = await store.writeSiteDraftToProject(draftID: draft.id)
      XCTAssertTrue(didWrite)
      await store.waitForPendingSiteDraftFileWrites()
      let boundDraft = try XCTUnwrap(store.drafts.first { $0.id == draft.id })
      initialDocuments[draft.id] = try String(contentsOf: url(for: boundDraft), encoding: .utf8)
      return boundDraft
    }
  }

  private func makeFixture(prefix: String) async throws -> Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)")
    let repository = base.appendingPathComponent("repository")
    try FileManager.default.createDirectory(
      at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: base.appendingPathComponent("app-data/workbench.json")),
      safeMode: true
    )
    store.updateActiveProfile {
      $0.localRepositoryRootPath = repository.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }
    await store.waitForPendingSave()
    return Fixture(baseURL: base, repositoryURL: repository, store: store)
  }

  private func copyRepository(from source: URL, to destination: URL) throws {
    try FileManager.default.copyItem(at: source, to: destination)
  }
}
