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
