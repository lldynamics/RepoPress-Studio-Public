import XCTest
@testable import PublishingWorkbenchCore

final class AssetResourceManagerServiceTests: XCTestCase {
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

  private func profile(rootURL: URL) -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.assetRoot = "static"
    return profile
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AssetResourceManagerServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
