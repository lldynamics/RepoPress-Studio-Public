import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class StructuralDraftRepairTests: XCTestCase {
  func testRepairPreservesContentIdentityAndUnselectedRecordsWithoutTouchingRepository()
    async throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let original = try XCTUnwrap(store.drafts.first)
    let untouched = store.drafts[1]
    let beforeFiles = try git(["status", "--porcelain"], root: fixture.repository)
    let preview = try await store.previewStructuralDraftRepair()
    XCTAssertEqual(preview.drafts.map(\.id), [original.id])
    XCTAssertFalse(preview.files.isEmpty)
    let result = try await store.applyStructuralDraftRepair(
      preview: preview,
      selectedDraftIDs: [original.id], selectedPaths: [])
    let repaired = try XCTUnwrap(store.drafts.first { $0.id == original.id })
    XCTAssertTrue(repaired.isGeneralDraft)
    XCTAssertEqual(repaired.bodyMarkdown, original.bodyMarkdown)
    XCTAssertEqual(repaired.attachments, original.attachments)
    XCTAssertEqual(repaired.title, original.title)
    XCTAssertNil(repaired.repositoryBinding)
    XCTAssertNil(repaired.repositoryPath)
    XCTAssertGreaterThan(repaired.editorMetadataRevision, original.editorMetadataRevision)
    XCTAssertEqual(store.drafts.first { $0.id == untouched.id }, untouched)
    XCTAssertTrue(store.draftRepositoryCleanupRequests.isEmpty)
    XCTAssertTrue(store.recycledDrafts.isEmpty)
    XCTAssertEqual(try git(["status", "--porcelain"], root: fixture.repository), beforeFiles)
    let backup = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: Data(contentsOf: result.backupURL.appendingPathComponent("workbench-before.json")))
    XCTAssertEqual(backup.drafts.first { $0.id == original.id }, original)
    let persisted = try XCTUnwrap(WorkbenchPersistence(fileURL: fixture.persistenceURL).load())
    XCTAssertTrue(try XCTUnwrap(persisted.drafts.first { $0.id == original.id }).isGeneralDraft)
    XCTAssertFalse(
      store.updateDraftFromEditor(original), "Stale editor must not restore old site scope")
  }

  func testSelectedFilesRestoreFromPinnedCommitWithoutStagingOrChangingOtherFiles() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preview = try await fixture.store.previewStructuralDraftRepair()
    let head = try git(["rev-parse", "HEAD"], root: fixture.repository)
    let selectedPath = "content/_index.md"
    let result = try await fixture.store.applyStructuralDraftRepair(
      preview: preview,
      selectedDraftIDs: [], selectedPaths: [selectedPath])
    XCTAssertNil(result.fileRecoveryError)
    XCTAssertEqual(result.restoredPaths, [selectedPath])
    XCTAssertEqual(
      try String(
        contentsOf: fixture.repository.appendingPathComponent(selectedPath), encoding: .utf8),
      "+++\ntitle = \"Home\"\n+++\n")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.repository.appendingPathComponent("content/posts/_index.md").path))
    XCTAssertEqual(
      try String(
        contentsOf: fixture.repository.appendingPathComponent("content/post.md"), encoding: .utf8),
      "unrelated user edit")
    XCTAssertEqual(try git(["diff", "--cached", "--name-only"], root: fixture.repository), "")
    XCTAssertEqual(try git(["rev-parse", "HEAD"], root: fixture.repository), head)
    XCTAssertEqual(
      try String(
        contentsOf: result.backupURL.appendingPathComponent("original-0.md"), encoding: .utf8),
      "wrong legacy content")
  }

  func testRepairBackupIncludesUncommittedEditorBodyWithoutWritingSection() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let id = try XCTUnwrap(store.drafts.first?.id)
    store.publishingStore.setDraftBodyEditorBuffer(
      .init(draftID: id, bodyMarkdown: "unsaved editor body", revision: 7, isDirty: true),
      for: id, notifyObservers: false)
    let preview = try await store.previewStructuralDraftRepair()
    let result = try await store.applyStructuralDraftRepair(
      preview: preview,
      selectedDraftIDs: [id], selectedPaths: [])
    let backup = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: Data(contentsOf: result.backupURL.appendingPathComponent("workbench-before.json")))
    XCTAssertEqual(backup.drafts.first { $0.id == id }?.bodyMarkdown, "unsaved editor body")
    XCTAssertEqual(store.drafts.first { $0.id == id }?.bodyMarkdown, "unsaved editor body")
    XCTAssertFalse(store.draftBodyEditorBuffer(for: id).isDirty)
    XCTAssertEqual(
      try String(
        contentsOf: fixture.repository.appendingPathComponent("content/_index.md"), encoding: .utf8),
      "wrong legacy content")
  }

  func testUnknownSelectionAndChangedProfileAreRejected() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let preview = try await store.previewStructuralDraftRepair()
    await assertRejected {
      _ = try await store.applyStructuralDraftRepair(
        preview: preview,
        selectedDraftIDs: [UUID()], selectedPaths: [])
    }
    await assertRejected {
      _ = try await store.applyStructuralDraftRepair(
        preview: preview,
        selectedDraftIDs: [], selectedPaths: ["content/post.md"])
    }
    store.updateActiveProfile { $0.branch = "another-branch" }
    await assertRejected {
      _ = try await store.applyStructuralDraftRepair(
        preview: preview,
        selectedDraftIDs: Set(preview.drafts.map(\.id)), selectedPaths: [])
    }
    XCTAssertFalse(try XCTUnwrap(store.drafts.first).isGeneralDraft)
  }

  func testDirtyEditorBufferAfterPreviewRejectsWithoutBackupOrMutation() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let id = try XCTUnwrap(store.drafts.first?.id)
    let preview = try await store.previewStructuralDraftRepair()
    let buffer = store.draftBodyEditorBuffer(for: id)
    _ = store.stageDraftBody("new unsaved user edit", for: id, baseRevision: buffer.revision)
    await assertRejected {
      _ = try await store.applyStructuralDraftRepair(
        preview: preview, selectedDraftIDs: [id], selectedPaths: [])
    }
    XCTAssertFalse(try XCTUnwrap(store.drafts.first { $0.id == id }).isGeneralDraft)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: id).bodyMarkdown, "new unsaved user edit")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("data/RecoveryArchives").path))
  }

  func testExternalFileEditAfterPreviewRejectsWholeRepair() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preview = try await fixture.store.previewStructuralDraftRepair()
    let path = "content/_index.md"
    try "concurrent external edit".write(
      to: fixture.repository.appendingPathComponent(path), atomically: true, encoding: .utf8)
    await assertRejected {
      _ = try await fixture.store.applyStructuralDraftRepair(
        preview: preview,
        selectedDraftIDs: Set(preview.drafts.map(\.id)), selectedPaths: [path])
    }
    XCTAssertFalse(try XCTUnwrap(fixture.store.drafts.first).isGeneralDraft)
    XCTAssertEqual(
      try String(contentsOf: fixture.repository.appendingPathComponent(path), encoding: .utf8),
      "concurrent external edit")
  }

  func testBackupFailureLeavesAllDraftsAndFilesUnchanged() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preview = try await fixture.store.previewStructuralDraftRepair()
    let originals = fixture.store.drafts
    try FileManager.default.createDirectory(
      at: fixture.persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "blocking file".write(
      to: fixture.persistenceURL.deletingLastPathComponent().appendingPathComponent(
        "RecoveryArchives"), atomically: true, encoding: .utf8)
    await assertRejected {
      _ = try await fixture.store.applyStructuralDraftRepair(
        preview: preview,
        selectedDraftIDs: Set(preview.drafts.map(\.id)), selectedPaths: [])
    }
    XCTAssertEqual(fixture.store.drafts, originals)
    XCTAssertEqual(
      try String(
        contentsOf: fixture.repository.appendingPathComponent("content/_index.md"), encoding: .utf8),
      "wrong legacy content")
  }

  func testPrimarySaveFailureKeepsOriginalRecordsAndBackup() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preview = try await fixture.store.previewStructuralDraftRepair()
    let originals = fixture.store.drafts
    try FileManager.default.createDirectory(
      at: fixture.persistenceURL, withIntermediateDirectories: true)
    await assertRejected {
      _ = try await fixture.store.applyStructuralDraftRepair(
        preview: preview,
        selectedDraftIDs: Set(preview.drafts.map(\.id)), selectedPaths: ["content/_index.md"])
    }
    XCTAssertEqual(fixture.store.drafts, originals)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.persistenceURL.deletingLastPathComponent().appendingPathComponent(
          "RecoveryArchives"
        ).path
      ).count, 1)
    XCTAssertEqual(
      try String(
        contentsOf: fixture.repository.appendingPathComponent("content/_index.md"), encoding: .utf8),
      "wrong legacy content")
  }

  func testSymlinkAndPendingTransactionAreNotOfferedForRestoration() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let path = fixture.repository.appendingPathComponent("content/_index.md")
    try FileManager.default.removeItem(at: path)
    let outside = fixture.root.appendingPathComponent("outside.md")
    try "outside content".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
    let service = StructuralDraftRepairService()
    var preview = service.preview(
      profile: fixture.store.activeProfile, drafts: fixture.store.drafts)
    XCTAssertFalse(preview.files.contains { $0.repositoryPath == "content/_index.md" })
    try "unfinished transaction".write(
      to: fixture.repository.appendingPathComponent(LocalPublishPreviewService.transactionFileName),
      atomically: true, encoding: .utf8)
    preview = service.preview(profile: fixture.store.activeProfile, drafts: fixture.store.drafts)
    XCTAssertTrue(preview.files.isEmpty)
    XCTAssertFalse(preview.drafts.isEmpty)
    XCTAssertFalse(preview.warnings.isEmpty)
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside content")
  }

  private func assertRejected(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Expected rejection")
    } catch {}
  }

  private func makeFixture() throws -> (
    root: URL, repository: URL, persistenceURL: URL, store: WorkbenchStore
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StructuralRepair-\(UUID())")
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("content/posts"), withIntermediateDirectories: true)
    try "+++\ntitle = \"Home\"\n+++\n".write(
      to: repo.appendingPathComponent("content/_index.md"), atomically: true, encoding: .utf8)
    try "+++\ntitle = \"Posts\"\n+++\n".write(
      to: repo.appendingPathComponent("content/posts/_index.md"), atomically: true, encoding: .utf8)
    try "original article".write(
      to: repo.appendingPathComponent("content/post.md"), atomically: true, encoding: .utf8)
    _ = try git(["init", "-q"], root: repo)
    _ = try git(["add", "--", "content"], root: repo)
    _ = try git(
      [
        "-c", "user.name=Repair Test", "-c", "user.email=repair@example.invalid", "-c",
        "commit.gpgsign=false", "commit", "-q", "-m", "fixture",
      ], root: repo)
    try "wrong legacy content".write(
      to: repo.appendingPathComponent("content/_index.md"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: repo.appendingPathComponent("content/posts/_index.md"))
    try "unrelated user edit".write(
      to: repo.appendingPathComponent("content/post.md"), atomically: true, encoding: .utf8)
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = repo.path
    profile.markdownPathPattern = "content/{slug}.md"
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let legacy = ArticleDraft(
      siteProfileID: profile.id, title: "Legacy home", date: instant, slug: "_index",
      bodyMarkdown: "preserve this user content", wordCount: 4, status: .published,
      createdAt: instant, updatedAt: instant, repositoryPath: "content/_index.md")
    let article = ArticleDraft(
      siteProfileID: profile.id, title: "Unrelated", date: instant,
      slug: "post", bodyMarkdown: "unrelated draft", wordCount: 2, createdAt: instant,
      updatedAt: instant)
    let snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id, drafts: [legacy, article],
      softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion, releaseRecords: [])
    let persistenceURL = root.appendingPathComponent("data/workbench.json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(.init(snapshot: snapshot)), safeMode: true)
    return (root, repo, persistenceURL, store)
  }

  private func git(_ arguments: [String], root: URL) throws -> String {
    let result = GitCommandRunner().run(arguments, rootURL: root)
    guard result.terminationStatus == 0 else {
      throw StructuralDraftRepairError.unavailable(result.output)
    }
    return result.standardOutput
  }
}
