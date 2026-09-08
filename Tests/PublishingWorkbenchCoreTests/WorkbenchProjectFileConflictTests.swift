import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchProjectFileConflictTests: XCTestCase {
  func testKeepBothPreservesDiskDocumentAndLocalOriginal() async throws {
    let fixture = try await makeFixture(prefix: "project-conflict-keep-both")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "keep-both", body: "Original body")
    let documentURL = try fixture.documentURL(for: draft)
    let externalDocument = try fixture.writeExternalDocument(for: draft, body: "External body")
    try fixture.updateLocalDraft(id: draft.id, body: "Local body")
    let review = try await fixture.store.prepareProjectFileConflictReview(draftID: draft.id)

    try await fixture.store.resolveProjectFileConflict(review, resolution: .keepBoth)

    XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), externalDocument)
    XCTAssertEqual(fixture.store.drafts.count, 2)
    XCTAssertEqual(fixture.store.drafts.first { $0.id == draft.id }?.bodyMarkdown, "External body")
    XCTAssertEqual(fixture.store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, "External body")
    XCTAssertEqual(
      fixture.store.drafts.first(where: { $0.id != draft.id })?.bodyMarkdown,
      "Local body"
    )
    XCTAssertTrue(fixture.store.drafts.first(where: { $0.id != draft.id })?.isGeneralDraft == true)
  }

  func testUseDiskStillRetainsLocalOriginalAsGeneralRecoveryCopy() async throws {
    let fixture = try await makeFixture(prefix: "project-conflict-use-disk")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "use-disk", body: "Original body")
    let documentURL = try fixture.documentURL(for: draft)
    let externalDocument = try fixture.writeExternalDocument(for: draft, body: "External body")
    try fixture.updateLocalDraft(id: draft.id, body: "Local body")
    let review = try await fixture.store.prepareProjectFileConflictReview(draftID: draft.id)

    try await fixture.store.resolveProjectFileConflict(review, resolution: .useDisk)

    XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), externalDocument)
    XCTAssertEqual(fixture.store.drafts.first { $0.id == draft.id }?.bodyMarkdown, "External body")
    XCTAssertEqual(fixture.store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, "External body")
    XCTAssertEqual(
      fixture.store.drafts.first(where: { $0.id != draft.id })?.bodyMarkdown,
      "Local body"
    )
  }

  func testStaleDiskRejectsConflictResolutionWithoutReplacingExternalContent() async throws {
    let fixture = try await makeFixture(prefix: "project-conflict-stale")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "stale", body: "Original body")
    let documentURL = try fixture.documentURL(for: draft)
    _ = try fixture.writeExternalDocument(for: draft, body: "First external body")
    try fixture.updateLocalDraft(id: draft.id, body: "Local body")
    let review = try await fixture.store.prepareProjectFileConflictReview(draftID: draft.id)
    let newerExternalDocument = try fixture.writeExternalDocument(for: draft, body: "Newer external body")

    do {
      try await fixture.store.resolveProjectFileConflict(review, resolution: .useDisk)
      XCTFail("A review must not resolve after the disk bytes have changed.")
    } catch {
      XCTAssertEqual(
        try String(contentsOf: documentURL, encoding: .utf8),
        newerExternalDocument
      )
      XCTAssertEqual(fixture.store.drafts.count, 1)
      XCTAssertEqual(fixture.store.drafts.first?.bodyMarkdown, "Local body")
    }
  }

  func testMergeWritesOnlyAgainstReviewedDiskDigestAndRetainsLocalCopy() async throws {
    let fixture = try await makeFixture(prefix: "project-conflict-merge")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "merge", body: "Original body")
    let documentURL = try fixture.documentURL(for: draft)
    _ = try fixture.writeExternalDocument(for: draft, body: "External body")
    try fixture.updateLocalDraft(id: draft.id, body: "Local body")
    let review = try await fixture.store.prepareProjectFileConflictReview(draftID: draft.id)
    let mergedDocument = review.diskDocument.replacingOccurrences(
      of: "External body", with: "External body\n\nMerged local addition")

    try await fixture.store.resolveProjectFileConflict(
      review, resolution: .mergedDocument(mergedDocument))

    XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), mergedDocument)
    XCTAssertTrue(
      fixture.store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown
        .contains("Merged local addition") == true
    )
    XCTAssertEqual(
      fixture.store.drafts.first(where: { $0.id != draft.id })?.bodyMarkdown,
      "Local body"
    )
  }

  func testReplacingRepositoryAtSamePathInvalidatesReviewEvenWithIdenticalBytes() async throws {
    let fixture = try await makeFixture(prefix: "project-conflict-root-replacement")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "same-path", body: "Original")
    let disk = try fixture.writeExternalDocument(for: draft, body: "External")
    try fixture.updateLocalDraft(id: draft.id, body: "Local")
    let review = try await fixture.store.prepareProjectFileConflictReview(draftID: draft.id)
    let moved = fixture.baseURL.appendingPathComponent("old-repository")
    try FileManager.default.moveItem(at: fixture.repositoryURL, to: moved)
    try FileManager.default.copyItem(at: moved, to: fixture.repositoryURL)
    do {
      try await fixture.store.resolveProjectFileConflict(review, resolution: .mergedDocument(review.draftDocument))
      XCTFail("Replacing the repository must invalidate its review")
    } catch {
      XCTAssertEqual(try String(contentsOf: fixture.documentURL(for: draft), encoding: .utf8), disk)
      XCTAssertEqual(fixture.store.drafts.first { $0.id == draft.id }?.bodyMarkdown, "Local")
    }
  }

  func testDiskAdoptionPreservesExactArchiveAndAllowsNextEdit() async throws {
    let fixture = try await makeFixture(prefix: "project-conflict-next-edit")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "next-edit", body: "Original")
    let disk = try fixture.writeExternalDocument(for: draft, body: "External")
    try fixture.updateLocalDraft(id: draft.id, body: "Local")
    let review = try await fixture.store.prepareProjectFileConflictReview(draftID: draft.id)
    try await fixture.store.resolveProjectFileConflict(review, resolution: .useDisk)
    let archiveRoot = fixture.baseURL.appendingPathComponent("app-data/RecoveryArchives/ProjectFileConflicts")
    let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: nil).first)
    XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("project.md"), encoding: .utf8), disk)
    let original = try JSONDecoder.workbench.decode(ArticleDraft.self, from: Data(contentsOf: archive.appendingPathComponent("draft.json")))
    XCTAssertEqual(try JSONEncoder.workbench.encode(original), try JSONEncoder.workbench.encode(review.draft))
    let buffer = fixture.store.draftBodyEditorBuffer(for: draft.id)
    _ = fixture.store.stageDraftBody("External plus next edit", for: draft.id, baseRevision: buffer.revision)
    let result = await fixture.store.prepareForSafeTermination()
    XCTAssertEqual(result, .saved)
    XCTAssertTrue(try String(contentsOf: fixture.documentURL(for: draft), encoding: .utf8).contains("External plus next edit"))
  }

  @MainActor
  private struct Fixture {
    let baseURL: URL
    let repositoryURL: URL
    let store: WorkbenchStore

    func documentURL(for draft: ArticleDraft) throws -> URL {
      repositoryURL.appendingPathComponent(try XCTUnwrap(draft.repositoryPath))
    }

    func addDraft(slug: String, body: String) async throws -> ArticleDraft {
      if store.selectedDraft == nil { store.createDraft() }
      var draft = try XCTUnwrap(store.selectedDraft)
      draft.slug = slug
      draft.title = slug
      draft.bodyMarkdown = body
      store.updateDraft(draft)
      let didWrite = await store.writeSiteDraftToProject(draftID: draft.id)
      XCTAssertTrue(didWrite)
      await store.waitForPendingSiteDraftFileWrites()
      return try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    }

    func updateLocalDraft(id: UUID, body: String) throws {
      var draft = try XCTUnwrap(store.drafts.first { $0.id == id })
      draft.bodyMarkdown = body
      store.updateDraft(draft)
    }

    func writeExternalDocument(for draft: ArticleDraft, body: String) throws -> String {
      var externalDraft = draft
      externalDraft.bodyMarkdown = body
      let document = FrontMatterRenderer().renderDocument(
        draft: externalDraft, profile: store.activeProfile)
      try document.write(to: documentURL(for: draft), atomically: true, encoding: .utf8)
      return document
    }
  }

  private func makeFixture(prefix: String) async throws -> Fixture {
    let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)")
    let repositoryURL = baseURL.appendingPathComponent("repository")
    try FileManager.default.createDirectory(
      at: repositoryURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let store = makeSafeExitTestStore(
      persistence: WorkbenchPersistence(fileURL: baseURL.appendingPathComponent("app-data/workbench.json")))
    store.updateActiveProfile {
      $0.localRepositoryRootPath = repositoryURL.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }
    await store.waitForPendingSave()
    return Fixture(baseURL: baseURL, repositoryURL: repositoryURL, store: store)
  }
}
