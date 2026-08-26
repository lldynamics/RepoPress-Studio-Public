import XCTest
@testable import PublishingWorkbenchCore

final class RepositoryImageInventoryServiceTests: XCTestCase {
  func testInventoryScansOnlySupportedRegularImagesAndBuildsArticleReferences() throws {
    let rootURL = try temporaryDirectory()
    let imageDirectory = rootURL.appendingPathComponent("static/images/2026", isDirectory: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: imageDirectory.appendingPathComponent("used.jpg"))
    try Data([4, 5]).write(to: imageDirectory.appendingPathComponent("diagram.SVG"))
    try Data([6]).write(to: imageDirectory.appendingPathComponent("notes.txt"))
    try Data([7]).write(to: imageDirectory.appendingPathComponent(".hidden.png"))
    try Data([8]).write(to: rootURL.appendingPathComponent("outside.png"))

    let escapedTarget = rootURL.deletingLastPathComponent().appendingPathComponent("escaped-\(UUID().uuidString).png")
    try Data([9]).write(to: escapedTarget)
    defer { try? FileManager.default.removeItem(at: escapedTarget) }
    try FileManager.default.createSymbolicLink(
      at: imageDirectory.appendingPathComponent("escaped.png"),
      withDestinationURL: escapedTarget
    )

    let firstAttachment = DraftAttachment(
      originalFilename: "used.jpg",
      relativePublishPath: "/images/2026/used.jpg",
      repositoryPath: "static/images/2026/used.jpg"
    )
    let firstDraft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "First Article",
      slug: "first",
      coverAttachmentID: firstAttachment.id,
      attachments: [
        firstAttachment,
        DraftAttachment(
          originalFilename: "used-again.jpg",
          relativePublishPath: "/images/2026/used.jpg",
          repositoryPath: "static/images/2026/used.jpg"
        ),
      ]
    )
    let secondAttachment = DraftAttachment(
      originalFilename: "used.jpg",
      relativePublishPath: "/images/2026/used.jpg",
      repositoryPath: "static/images/2026/used.jpg"
    )
    let secondDraft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Second Article",
      slug: "second",
      attachments: [secondAttachment]
    )
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.assetRoot = "static"

    let inventory = try RepositoryImageInventoryService().inventory(
      drafts: [secondDraft, firstDraft],
      profile: profile
    )

    XCTAssertEqual(
      inventory.assets.map(\.repositoryPath),
      ["static/images/2026/diagram.SVG", "static/images/2026/used.jpg"]
    )
    XCTAssertEqual(inventory.totalByteSize, 5)
    XCTAssertEqual(inventory.registeredCount, 1)
    XCTAssertEqual(inventory.unregisteredCount, 1)
    XCTAssertFalse(inventory.wasTruncated)

    let used = try XCTUnwrap(inventory.assets.last)
    XCTAssertEqual(used.references.map(\.draftTitle), ["First Article", "Second Article"])
    XCTAssertEqual(used.references.map(\.isCover), [true, false])
  }

  func testValidatedAssetLocationRejectsUnsafeOrUnavailablePaths() throws {
    let rootURL = try temporaryDirectory()
    let imageDirectory = rootURL.appendingPathComponent("static/images", isDirectory: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let validURL = imageDirectory.appendingPathComponent("valid.png")
    try Data([1, 2, 3, 4]).write(to: validURL)
    try Data([5]).write(to: rootURL.appendingPathComponent("outside.png"))
    try Data([6]).write(to: imageDirectory.appendingPathComponent("invalid.txt"))

    let externalURL = rootURL.deletingLastPathComponent().appendingPathComponent("external-\(UUID().uuidString).jpg")
    try Data([7]).write(to: externalURL)
    defer { try? FileManager.default.removeItem(at: externalURL) }
    try FileManager.default.createSymbolicLink(
      at: imageDirectory.appendingPathComponent("external.jpg"),
      withDestinationURL: externalURL
    )

    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.assetRoot = "static"
    let service = RepositoryImageInventoryService()

    let valid = try service.validatedAssetLocation(
      profile: profile,
      repositoryPath: "static/images/valid.png"
    )
    XCTAssertEqual(valid.repositoryPath, "static/images/valid.png")
    XCTAssertEqual(valid.byteSize, 4)

    assertInventoryError(.invalidRepositoryPath) {
      try service.validatedAssetLocation(profile: profile, repositoryPath: "../outside.png")
    }
    assertInventoryError(.invalidRepositoryPath) {
      try service.validatedAssetLocation(profile: profile, repositoryPath: validURL.path)
    }
    assertInventoryError(.pathOutsideAssetRoot) {
      try service.validatedAssetLocation(profile: profile, repositoryPath: "outside.png")
    }
    assertInventoryError(.unsupportedImageFormat) {
      try service.validatedAssetLocation(profile: profile, repositoryPath: "static/images/invalid.txt")
    }
    assertInventoryError(.imageFileUnavailable("static/images/missing.png")) {
      try service.validatedAssetLocation(profile: profile, repositoryPath: "static/images/missing.png")
    }
    assertInventoryError(.pathOutsideAssetRoot) {
      try service.validatedAssetLocation(profile: profile, repositoryPath: "static/images/external.jpg")
    }
  }

  func testInventoryReportsMissingRepositoryAndAssetDirectory() throws {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = ""
    let service = RepositoryImageInventoryService()

    assertInventoryError(.repositoryUnavailable) {
      try service.inventory(drafts: [], profile: profile)
    }

    let rootURL = try temporaryDirectory()
    profile.localRepositoryRootPath = rootURL.path
    assertInventoryError(.assetDirectoryUnavailable("static")) {
      try service.inventory(drafts: [], profile: profile)
    }

    let actualAssetDirectory = rootURL.appendingPathComponent("actual-static", isDirectory: true)
    try FileManager.default.createDirectory(at: actualAssetDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("linked-static"),
      withDestinationURL: actualAssetDirectory
    )
    profile.assetRoot = "linked-static"
    assertInventoryError(.unsafeAssetRoot) {
      try service.inventory(drafts: [], profile: profile)
    }
  }

  func testInventoryAsyncHonorsCancellationBeforeReturningAResult() async throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static", isDirectory: true),
      withIntermediateDirectories: true
    )
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.assetRoot = "static"

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await RepositoryImageInventoryService().inventoryAsync(
        drafts: [],
        profile: profile
      )
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  private func assertInventoryError<T>(
    _ expected: RepositoryImageInventoryError,
    operation: () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      XCTAssertEqual(error as? RepositoryImageInventoryError, expected, file: file, line: line)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryImageInventoryServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
