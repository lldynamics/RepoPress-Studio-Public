import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class ImageBatchTaskOwnershipTests: XCTestCase {
  func testOwnerRemainsBoundToResolvedSiteAfterActiveProfileChanges() throws {
    let persistenceURL = try temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let originalProfile = store.activeProfile
    var otherProfile = SiteProfile.defaultProfile
    otherProfile.id = UUID()
    otherProfile.name = "Other"
    store.setProfiles(store.profiles + [otherProfile])

    let originalDraft = draft(profileID: originalProfile.id, title: "Original")
    let otherDraft = draft(profileID: otherProfile.id, title: "Other")
    store.setDrafts([originalDraft, otherDraft])

    store.imageStore.captureImageBatchTaskOwner(for: [originalDraft])
    XCTAssertEqual(
      store.imageStore.imageBatchTaskOwner,
      ImageBatchTaskOwner(profileID: originalProfile.id, draftID: originalDraft.id)
    )

    store.selectProfile(otherProfile.id)

    XCTAssertEqual(store.activeProfileID, otherProfile.id)
    XCTAssertEqual(
      store.imageStore.imageBatchTaskOwner,
      ImageBatchTaskOwner(profileID: originalProfile.id, draftID: originalDraft.id)
    )
  }

  func testNextBatchReplacesOwnerAndMultiSiteBatchHasNoProfileFallback() throws {
    let persistenceURL = try temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let originalProfile = store.activeProfile
    var otherProfile = SiteProfile.defaultProfile
    otherProfile.id = UUID()
    otherProfile.name = "Other"
    store.setProfiles(store.profiles + [otherProfile])

    let originalDraft = draft(profileID: originalProfile.id, title: "Original")
    let otherDraft = draft(profileID: otherProfile.id, title: "Other")

    store.imageStore.captureImageBatchTaskOwner(for: [originalDraft])
    store.imageStore.captureImageBatchTaskOwner(for: [otherDraft])

    XCTAssertEqual(
      store.imageStore.imageBatchTaskOwner,
      ImageBatchTaskOwner(profileID: otherProfile.id, draftID: otherDraft.id)
    )

    store.imageStore.captureImageBatchTaskOwner(for: [originalDraft, otherDraft])

    XCTAssertEqual(
      store.imageStore.imageBatchTaskOwner,
      ImageBatchTaskOwner(profileID: nil, draftID: nil)
    )
  }

  func testCompletedBatchRetainsOwnerUntilTheNextBatchStarts() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let profile = store.activeProfile
    var otherProfile = SiteProfile.defaultProfile
    otherProfile.id = UUID()
    store.setProfiles(store.profiles + [otherProfile])
    let draft = draft(profileID: profile.id, title: "No Attachments")
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.optimizeSelectedDraftJPEGImages()
    store.selectProfile(otherProfile.id)
    let runningTask = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.id == "image-processing" }
    )
    XCTAssertEqual(
      runningTask.target, .siteProfilePage(profileID: profile.id, section: .images)
    )

    XCTAssertEqual(
      store.imageStore.imageBatchTaskOwner,
      ImageBatchTaskOwner(profileID: profile.id, draftID: draft.id)
    )
    for _ in 0..<100 where store.imageStore.isImageBatchProcessing {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertFalse(store.imageStore.isImageBatchProcessing)
    XCTAssertEqual(
      store.imageStore.imageBatchTaskOwner,
      ImageBatchTaskOwner(profileID: profile.id, draftID: draft.id)
    )
  }

  private func draft(profileID: UUID, title: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profileID,
      title: title,
      slug: title.lowercased()
    )
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageBatchTaskOwnership-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}

@MainActor
final class ImageBatchRetentionTests: XCTestCase {
  func testStartupPreservesImagesOutsideLiveDraftsIncludingRecoveryAndInFlightBatches() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchPersistence(
      fileURL: directory.appendingPathComponent("workbench.json"))
    let profile = SiteProfile.defaultProfile
    let live = ArticleDraft(siteProfileID: profile.id, title: "Live", slug: "live")
    var version = live
    version.attachments = [try attachment("history", persistence: persistence)]
    let recycled = ArticleDraft(
      siteProfileID: profile.id, title: "Deleted", slug: "deleted",
      attachments: [try attachment("recycle", persistence: persistence)])
    let backup = ArticleDraft(
      siteProfileID: profile.id, title: "Backup", slug: "backup",
      attachments: [try attachment("last-good", persistence: persistence)])
    var snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id,
      drafts: [backup], releaseRecords: [])
    _ = try persistence.save(snapshot)
    snapshot.drafts = [live]
    snapshot.draftVersions = [DraftVersionSnapshot(draft: version, reason: .manual)]
    snapshot.recycledDrafts = [RecycledDraft(draft: recycled)]
    _ = try persistence.save(snapshot)
    let archiveOnly = try attachment("archived", persistence: persistence)
    let inFlight = try attachment("in-flight", persistence: persistence)
    let recoveryURL = persistence.recoveryArchiveDirectoryURL.appendingPathComponent(
      "snapshot.json")
    try FileManager.default.createDirectory(
      at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var archived = live
    archived.attachments = [archiveOnly]
    try JSONEncoder().encode(archived).write(to: recoveryURL)

    let store = WorkbenchStore(persistence: persistence)
    _ = store.imageStore
    for attachment in version.attachments + recycled.attachments + backup.attachments + [
      archiveOnly, inFlight,
    ] {
      XCTAssertEqual(
        try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(attachment.sourceFilePath))),
        Data("retained".utf8))
    }
  }

  func testSuccessfulBatchRetainsOriginalVersionAndUncommittedOtherBatch() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchPersistence(
      fileURL: directory.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(persistence: persistence)
    var source = try attachment("prior-success", persistence: persistence)
    let original = Data(
      "<svg xmlns=\"http://www.w3.org/2000/svg\"><!-- removable metadata --><rect width=\"10\" height=\"10\"/></svg>"
        .utf8)
    try original.write(to: URL(fileURLWithPath: XCTUnwrap(source.sourceFilePath)))
    source.byteSize = Int64(original.count)
    let other = try attachment("other-uncommitted", persistence: persistence)
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "SVG", slug: "svg",
      bodyMarkdown: "![image](/images/image.svg)", attachments: [source])
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.optimizeSelectedDraftSVGImages()
    for _ in 0..<250 where store.imageStore.isImageBatchProcessing {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(store.imageStore.isImageBatchProcessing)
    XCTAssertNil(store.imageStore.lastBatchFailure)
    let updated = try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    XCTAssertNotEqual(updated.attachments.first?.sourceFilePath, source.sourceFilePath)
    XCTAssertTrue(store.draftVersions.contains { $0.draft.attachments == [source] })
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(source.sourceFilePath))), original)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(other.sourceFilePath))),
      Data("retained".utf8))
  }

  private func attachment(_ name: String, persistence: WorkbenchPersistence) throws
    -> DraftAttachment
  {
    let url = persistence.imageOptimizationDirectoryURL
      .appendingPathComponent(".image-batch-\(name)").appendingPathComponent("image.svg")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("retained".utf8).write(to: url)
    return DraftAttachment(
      originalFilename: "image.svg", relativePublishPath: "/images/image.svg",
      repositoryPath: "static/images/image.svg", altText: "image", caption: "", byteSize: 8,
      sourceFilePath: url.path)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "image-retention-\(UUID().uuidString)")
  }
}
