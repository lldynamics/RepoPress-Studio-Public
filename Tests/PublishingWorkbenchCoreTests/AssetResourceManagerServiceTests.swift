import XCTest
@testable import PublishingWorkbenchCore

final class AssetResourceManagerServiceTests: XCTestCase {
  func testEncodedFilenameDelimitersRemainReferencedAndBlockStaleCleanup() throws {
    let root = try temporaryDirectory()
    let images = root.appendingPathComponent("static/images", isDirectory: true)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let filenames = ["photo#1.png", "photo?1.png", "photo%231.png", "normal.png"]
    for filename in filenames {
      try Data([1, 2]).write(to: images.appendingPathComponent(filename))
    }
    let service = AssetResourceManagerService()
    let profileID = UUID()
    let before = try service.scan(repositoryRootURL: root, assetRoot: "static", profileID: profileID)
    XCTAssertEqual(before.orphanedAssets.count, filenames.count)
    try """
      ![hash](/images/photo%231.png?width=200#preview)
      ![question](/images/photo%3F1.png#preview)
      ![percent](/images/photo%25231.png)
      ![normal](/images/normal.png?width=200#preview)
      """.write(to: root.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)

    let after = try service.scan(repositoryRootURL: root, assetRoot: "static", profileID: profileID)
    XCTAssertEqual(after.referencedAssetCount, filenames.count)
    XCTAssertTrue(after.brokenReferences.isEmpty)
    XCTAssertTrue(after.orphanedAssets.isEmpty)
    XCTAssertCleanupReviewChanged {
      try service.validateOrphanedAssetsForCleanup(
        repositoryRootURL: root, assetRoot: "static", profileID: profileID,
        items: before.orphanedAssets, reviewedReport: before)
    }
    for filename in filenames {
      XCTAssertTrue(FileManager.default.fileExists(atPath: images.appendingPathComponent(filename).path))
    }
  }

  func testScanFindsOrphanedImagesAttachmentsAndBrokenLocalReferences() throws {
    let rootURL = try temporaryDirectory()
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    let imagesURL = rootURL.appendingPathComponent("static/images", isDirectory: true)
    let filesURL = rootURL.appendingPathComponent("static/files", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)

    try Data(repeating: 1, count: 300_000).write(to: imagesURL.appendingPathComponent("used.jpg"))
    try Data([2, 3]).write(to: imagesURL.appendingPathComponent("orphan.png"))
    try Data([4, 5]).write(to: filesURL.appendingPathComponent("report.pdf"))
    try Data([6, 7]).write(to: rootURL.appendingPathComponent("outside.png"))
    try """
# Article

![used](/images/used.jpg)

<img src="/images/used.jpg">

[report](../../static/files/report.pdf)

![missing](/images/missing.png)

[outside](../../outside.png)

```markdown
![fake](/images/fake.png)
```

`![inline](/images/inline.png)`

![external](https://example.com/image.png)
""".write(
      to: postsURL.appendingPathComponent("article.md"),
      atomically: true,
      encoding: .utf8
    )
    let report = try AssetResourceManagerService().scan(
      repositoryRootURL: rootURL,
      assetRoot: "static",
      profileID: UUID()
    )

    XCTAssertEqual(
      report.assets.map(\.repositoryPath),
      ["static/files/report.pdf", "static/images/orphan.png", "static/images/used.jpg"]
    )
    XCTAssertEqual(report.referencedAssetCount, 2)
    XCTAssertEqual(report.orphanedAssets.map(\.repositoryPath), ["static/images/orphan.png"])
    XCTAssertEqual(report.orphanedByteSize, 2)
    XCTAssertEqual(report.compressionCandidates.map(\.repositoryPath), ["static/images/used.jpg"])

    let used = try XCTUnwrap(report.assets.first(where: { $0.repositoryPath == "static/images/used.jpg" }))
    XCTAssertEqual(used.references.count, 2)
    XCTAssertTrue(used.references.allSatisfy { $0.sourceMarkdownPath == "content/posts/article.md" })

    XCTAssertEqual(report.brokenReferences.count, 2)
    XCTAssertTrue(report.brokenReferences.contains { reference in
      reference.rawPath == "/images/missing.png" && reference.kind == .missing
    })
    XCTAssertTrue(report.brokenReferences.contains { reference in
      reference.rawPath == "../../outside.png" && reference.kind == .outsideAssetRoot
    })
    XCTAssertFalse(report.brokenReferences.contains { $0.rawPath.contains("fake.png") })
    XCTAssertFalse(report.brokenReferences.contains { $0.rawPath.contains("inline.png") })
    XCTAssertEqual(report.scannedMarkdownFileCount, 1)
  }

  func testScanRejectsAssetRootSymlink() throws {
    let rootURL = try temporaryDirectory()
    let actualURL = rootURL.appendingPathComponent("actual", isDirectory: true)
    try FileManager.default.createDirectory(at: actualURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("static"),
      withDestinationURL: actualURL
    )

    XCTAssertThrowsError(
      try AssetResourceManagerService().scan(
        repositoryRootURL: rootURL,
        assetRoot: "static"
      )
    ) { error in
      XCTAssertEqual(error as? AssetResourceManagerError, .invalidAssetRoot)
    }
  }

  func testScanAsyncHonorsCancellation() async throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static", isDirectory: true),
      withIntermediateDirectories: true
    )
    let scanProfile = profile(rootURL: rootURL)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AssetResourceManagerService().scanAsync(
        profile: scanProfile
      )
    }

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testCumulativeMarkdownBudgetMarksScanIncompleteAndPreventsSafeOrphanCleanup() throws {
    let rootURL = try temporaryDirectory()
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    let imagesURL = rootURL.appendingPathComponent("static/images", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    try Data([1]).write(to: imagesURL.appendingPathComponent("one.png"))
    try Data([2]).write(to: imagesURL.appendingPathComponent("two.png"))

    let firstDocument = "![one](/images/one.png)\n"
    let secondDocument = "![two](/images/two.png)\n"
    try firstDocument.write(
      to: postsURL.appendingPathComponent("01-first.md"), atomically: true, encoding: .utf8)
    try secondDocument.write(
      to: postsURL.appendingPathComponent("02-second.md"), atomically: true, encoding: .utf8)

    // Enumeration order is unspecified; either equally sized document fits.
    XCTAssertEqual(firstDocument.utf8.count, secondDocument.utf8.count)
    let cleanupProfile = profile(rootURL: rootURL)
    let constrainedService = AssetResourceManagerService(
      maximumTotalMarkdownByteCount: Int64(firstDocument.lengthOfBytes(using: .utf8))
    )
    let report = try constrainedService.scan(
      repositoryRootURL: rootURL, assetRoot: "static", profileID: cleanupProfile.id
    )

    XCTAssertEqual(report.scannedMarkdownFileCount, 1)
    XCTAssertTrue(report.wasTruncated)
    XCTAssertFalse(report.isComplete)
    XCTAssertEqual(report.referencedAssetCount, 1)
    XCTAssertEqual(report.orphanedAssets.count, 1)

    XCTAssertCleanupReviewChanged {
      _ = try constrainedService.moveOrphanedAssetsToTrash(
        profile: cleanupProfile,
        items: report.orphanedAssets,
        reviewedReport: report
      )
    }
    XCTAssertTrue(report.orphanedAssets.allSatisfy { FileManager.default.fileExists(atPath: $0.absoluteFilePath) })
  }

  func testCleanupRejectsReferenceAddedAfterReviewWithoutChangingAssetMetadata() throws {
    let rootURL = try temporaryDirectory()
    let postsURL = try makeAssetRepository(at: rootURL)
    let assetURL = rootURL.appendingPathComponent("static/images/stale.png")
    try Data([1, 2, 3]).write(to: assetURL)
    let cleanupProfile = profile(rootURL: rootURL)
    let service = AssetResourceManagerService()
    let report = try service.scan(profile: cleanupProfile)
    let item = try XCTUnwrap(report.orphanedAssets.first)
    let originalAttributes = try FileManager.default.attributesOfItem(atPath: assetURL.path)

    try "![now referenced](/images/stale.png)\n".write(
      to: postsURL.appendingPathComponent("new-reference.md"), atomically: true, encoding: .utf8
    )

    XCTAssertCleanupReviewChanged {
      _ = try service.moveOrphanedAssetsToTrash(
        profile: cleanupProfile, items: [item], reviewedReport: report
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
    let currentAttributes = try FileManager.default.attributesOfItem(atPath: assetURL.path)
    XCTAssertEqual(currentAttributes[.size] as? NSNumber, originalAttributes[.size] as? NSNumber)
    XCTAssertEqual(
      currentAttributes[.modificationDate] as? Date,
      originalAttributes[.modificationDate] as? Date
    )
  }

  func testCleanupRejectsEntireBatchWhenOneReviewedOrphanBecomesReferenced() throws {
    let rootURL = try temporaryDirectory()
    let postsURL = try makeAssetRepository(at: rootURL)
    let firstURL = rootURL.appendingPathComponent("static/images/first.png")
    let secondURL = rootURL.appendingPathComponent("static/images/second.png")
    try Data([1]).write(to: firstURL)
    try Data([2]).write(to: secondURL)
    let cleanupProfile = profile(rootURL: rootURL)
    let service = AssetResourceManagerService()
    let report = try service.scan(profile: cleanupProfile)
    XCTAssertEqual(report.orphanedAssets.count, 2)

    try "![first](/images/first.png)\n".write(
      to: postsURL.appendingPathComponent("first-is-now-used.md"), atomically: true, encoding: .utf8
    )
    let freshReport = try service.scan(profile: cleanupProfile)
    XCTAssertFalse(
      try XCTUnwrap(freshReport.assets.first(where: { $0.repositoryPath == "static/images/first.png" }))
        .isOrphaned
    )
    XCTAssertTrue(
      try XCTUnwrap(freshReport.assets.first(where: { $0.repositoryPath == "static/images/second.png" }))
        .isOrphaned
    )

    XCTAssertCleanupReviewChanged {
      _ = try service.moveOrphanedAssetsToTrash(
        profile: cleanupProfile, items: report.orphanedAssets, reviewedReport: report
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
  }

  func testCleanupRejectsReviewFromAnotherRepositoryAndProfile() throws {
    let firstRootURL = try temporaryDirectory()
    _ = try makeAssetRepository(at: firstRootURL)
    let firstAssetURL = firstRootURL.appendingPathComponent("static/images/shared.png")
    try Data([1]).write(to: firstAssetURL)
    let firstProfile = profile(rootURL: firstRootURL)
    let service = AssetResourceManagerService()
    let firstReport = try service.scan(profile: firstProfile)
    let reviewedItem = try XCTUnwrap(firstReport.orphanedAssets.first)

    let secondRootURL = try temporaryDirectory()
    _ = try makeAssetRepository(at: secondRootURL)
    let secondAssetURL = secondRootURL.appendingPathComponent("static/images/shared.png")
    try Data([2]).write(to: secondAssetURL)
    var secondProfile = profile(rootURL: secondRootURL)
    secondProfile.id = UUID()

    XCTAssertCleanupReviewChanged {
      _ = try service.moveOrphanedAssetsToTrash(
        profile: secondProfile, items: [reviewedItem], reviewedReport: firstReport
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstAssetURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondAssetURL.path))
  }

  func testUnchangedReviewPassesInternalValidationWithoutMovingAsset() throws {
    let rootURL = try temporaryDirectory()
    _ = try makeAssetRepository(at: rootURL)
    let assetURL = rootURL.appendingPathComponent("static/images/unchanged.png")
    try Data([1, 2]).write(to: assetURL)
    let cleanupProfile = profile(rootURL: rootURL)
    let service = AssetResourceManagerService()
    let report = try service.scan(profile: cleanupProfile)
    let item = try XCTUnwrap(report.orphanedAssets.first)

    XCTAssertNoThrow(
      try service.validateOrphanedAssetsForCleanup(
        repositoryRootURL: rootURL,
        assetRoot: cleanupProfile.assetRoot,
        profileID: cleanupProfile.id,
        items: [item],
        reviewedReport: report
      )
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
  }

  private func profile(rootURL: URL) -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.assetRoot = "static"
    return profile
  }

  private func makeAssetRepository(at rootURL: URL) throws -> URL {
    let postsURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    let imagesURL = rootURL.appendingPathComponent("static/images", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    return postsURL
  }

  private func XCTAssertCleanupReviewChanged(
    _ expression: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
      XCTAssertEqual(error as? AssetResourceManagerError, .cleanupReviewChanged, file: file, line: line)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AssetResourceManagerServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
