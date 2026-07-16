import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class AIPublishingRequestArtifactsTests: XCTestCase {
  func testArtifactsReuseOnePackageAndMatchingCachedPreview() async throws {
    let repositoryURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: repositoryURL) }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: repositoryURL.appendingPathComponent("snapshot.json"))
    )
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(repositoryURL)
    store.updateActiveProfile(profile)

    let draft = try XCTUnwrap(store.selectedDraft)
    store.refreshPublishPreview(for: draft)
    let cachedPreviewDate = try XCTUnwrap(store.localPublishPreview?.generatedAt)

    let artifacts = await store.aiPublishingRequestArtifacts(for: draft)
    let preview = try XCTUnwrap(artifacts.workflowContext.publishPreview)

    XCTAssertEqual(preview.package.id, artifacts.publishPackage.id)
    XCTAssertEqual(preview.package.files, artifacts.publishPackage.files)
    XCTAssertEqual(preview.generatedAt, cachedPreviewDate)
    XCTAssertEqual(artifacts.remoteReviewDraft.branchName, artifacts.publishPackage.reviewBranchName)
    XCTAssertEqual(artifacts.workflowContext.imageReport?.draftID, draft.id)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIPublishingRequestArtifactsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
