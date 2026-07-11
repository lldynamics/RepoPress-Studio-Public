import XCTest
@testable import PublishingWorkbenchCore

final class LocalPublishPreviewServiceTests: XCTestCase {
  func testPreviewReportsModifiedMarkdownFile() throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Updated",
      slug: "existing",
      draft: false,
      bodyMarkdown: "Updated body that should produce a modified file."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let preview = LocalPublishPreviewService().preview(package: package, profile: profile)
    let markdownDiff = try XCTUnwrap(preview.fileDiffs.first(where: { $0.kind == .markdown }))

    XCTAssertEqual(markdownDiff.status, .modified)
    XCTAssertTrue(markdownDiff.lineDiff?.contains("-old content") == true)
    XCTAssertTrue(markdownDiff.lineDiff?.contains("+title = \"Updated\"") == true)
  }

  func testPreviewUsesRepositoryBookmarkWhenStoredPathIsStale() throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/stale/path"
    profile.localRepositoryBookmarkData = try rootURL.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Updated",
      slug: "existing",
      draft: false,
      bodyMarkdown: "Updated body that should produce a modified file."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let preview = LocalPublishPreviewService().preview(package: package, profile: profile)

    XCTAssertTrue(preview.issues.isEmpty)
    XCTAssertEqual(preview.fileDiffs.first(where: { $0.kind == .markdown })?.status, .modified)
  }

  func testWritePackageCreatesMarkdownFileInsideRepository() throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "New Draft",
      slug: "new-draft",
      draft: false,
      bodyMarkdown: "New body that should be written to the repository."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let written = try LocalPublishPreviewService().write(package: package, profile: profile)
    let targetURL = rootURL.appendingPathComponent("content/posts/new-draft.md")
    let content = try String(contentsOf: targetURL, encoding: .utf8)

    XCTAssertEqual(written, ["content/posts/new-draft.md"])
    XCTAssertTrue(content.contains("title = \"New Draft\""))
  }

  func testWritePackageAsyncCreatesMarkdownFileInsideRepository() async throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Async Draft",
      slug: "async-draft",
      draft: false,
      bodyMarkdown: "New body that should be written outside the main actor."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let written = try await LocalPublishPreviewService().writeAsync(package: package, profile: profile)
    let targetURL = rootURL.appendingPathComponent("content/posts/async-draft.md")
    let content = try String(contentsOf: targetURL, encoding: .utf8)

    XCTAssertEqual(written, ["content/posts/async-draft.md"])
    XCTAssertTrue(content.contains("title = \"Async Draft\""))
  }

  func testPreviewRejectsUnsafeImageAttachmentPath() throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let imageURL = rootURL.appendingPathComponent("source-cover.jpg")
    try "fake image".write(to: imageURL, atomically: true, encoding: .utf8)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "/tmp/cover.jpg",
      altText: "Cover image",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unsafe Image",
      slug: "unsafe-image",
      draft: false,
      bodyMarkdown: "Body with enough content for a publish package.",
      attachments: [attachment]
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let preview = LocalPublishPreviewService().preview(package: package, profile: profile)
    let imageDiff = try XCTUnwrap(preview.fileDiffs.first(where: { $0.kind == .image }))

    XCTAssertEqual(imageDiff.status, .unsafePath)
    XCTAssertTrue(preview.issues.contains { $0.title == "发布路径不安全" && $0.message == "/tmp/cover.jpg" })
  }

  func testWriteRejectsRepositorySymlinkBeforeWritingOutsideRoot() throws {
    let rootURL = try makeRepositoryFixture()
    let outsideURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacOutside-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: rootURL.appendingPathComponent("content"))
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("content"),
      withDestinationURL: outsideURL
    )

    let package = publishPackage(
      files: [.init(kind: .markdown, repositoryPath: "content/posts/escape.md", content: "must not escape")]
    )
    let service = LocalPublishPreviewService()

    let preview = service.preview(package: package, rootURL: rootURL)
    XCTAssertEqual(preview.fileDiffs.first?.status, .unsafePath)
    XCTAssertThrowsError(try service.write(package: package, rootURL: rootURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("posts/escape.md").path))
  }

  func testWriteRejectsSymlinkBeforeDeletingImageOutsideRoot() throws {
    let rootURL = try makeRepositoryFixture()
    let outsideURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacOutside-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.jpg")
    try "replacement image".write(to: sourceURL, atomically: true, encoding: .utf8)
    let outsideImageURL = outsideURL.appendingPathComponent("cover.jpg")
    try "outside original".write(to: outsideImageURL, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("images"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("images/cover.jpg"),
      withDestinationURL: outsideImageURL
    )

    let package = publishPackage(
      files: [.init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)]
    )

    XCTAssertThrowsError(try LocalPublishPreviewService().write(package: package, rootURL: rootURL))
    XCTAssertEqual(try String(contentsOf: outsideImageURL, encoding: .utf8), "outside original")
  }

  func testWritePrevalidatesEveryDestinationBeforeChangingEarlierFiles() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let existingURL = rootURL.appendingPathComponent("content/posts/existing.md")
    let sourceURL = rootURL.appendingPathComponent("source.jpg")
    try "replacement image".write(to: sourceURL, atomically: true, encoding: .utf8)
    try "not a directory".write(
      to: rootURL.appendingPathComponent("blocked"),
      atomically: true,
      encoding: .utf8
    )
    let package = publishPackage(
      files: [
        .init(kind: .markdown, repositoryPath: "content/posts/existing.md", content: "new content"),
        .init(kind: .image, repositoryPath: "blocked/image.jpg", sourceFilePath: sourceURL.path),
      ]
    )

    XCTAssertThrowsError(try LocalPublishPreviewService().write(package: package, rootURL: rootURL))
    XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "old content\n")
  }

  func testWriteAtomicallyReplacesExistingImage() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
    try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    let destinationURL = imagesURL.appendingPathComponent("cover.jpg")
    let sourceURL = rootURL.appendingPathComponent("replacement.jpg")
    try Data("old image".utf8).write(to: destinationURL)
    try Data("new image".utf8).write(to: sourceURL)
    let package = publishPackage(
      files: [.init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)]
    )

    let written = try LocalPublishPreviewService().write(package: package, rootURL: rootURL)

    XCTAssertEqual(written, ["images/cover.jpg"])
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new image".utf8))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: imagesURL.path)
        .contains(where: { $0.contains("publisher-stage") })
    )
  }

  private func publishPackage(files: [PublishPackageFile]) -> PublishPackage {
    PublishPackage(
      draftID: UUID(),
      title: "Test",
      markdownPath: files.first?.repositoryPath ?? "content/posts/test.md",
      files: files,
      commitMessage: "test",
      reviewBranchName: "test",
      reviewTitle: "test",
      reviewChecklist: []
    )
  }

  private func makeRepositoryFixture() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacPublishTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "old content\n".write(
      to: rootURL.appendingPathComponent("content/posts/existing.md"),
      atomically: true,
      encoding: .utf8
    )
    return rootURL
  }
}
