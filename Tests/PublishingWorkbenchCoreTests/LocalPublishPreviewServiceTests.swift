import XCTest
@testable import PublishingWorkbenchCore

final class LocalPublishPreviewServiceTests: XCTestCase {
  func testStableFileResourceIdentifierDoesNotUseRandomizedHashing() {
    XCTAssertEqual(stableLocalPublishFileIdentifier(NSNumber(value: 42)), 42)
    XCTAssertEqual(
      stableLocalPublishFileIdentifier(Data("resource-id".utf8)),
      0x8D2C_84EB_1C1F_BB8B
    )
    XCTAssertNotEqual(
      stableLocalPublishFileIdentifier(Data("resource-id".utf8)),
      stableLocalPublishFileIdentifier(Data("other-resource-id".utf8))
    )
    XCTAssertEqual(stableLocalPublishFileIdentifier(NSObject()), 0)
  }

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

  func testPreviewBlocksUnreadableExistingMarkdownInsteadOfTreatingItAsEmpty() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let destinationURL = rootURL.appendingPathComponent("content/posts/existing.md")
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
    try invalidUTF8.write(to: destinationURL)
    let package = publishPackage(
      files: [
        .init(
          kind: .markdown,
          repositoryPath: "content/posts/existing.md",
          content: "replacement content"
        )
      ]
    )
    let service = LocalPublishPreviewService()

    let preview = service.preview(package: package, rootURL: rootURL)
    let diff = try XCTUnwrap(preview.fileDiffs.first)

    XCTAssertEqual(diff.status, .modified)
    XCTAssertNil(diff.lineDiff)
    XCTAssertNil(diff.baselineState)
    XCTAssertTrue(preview.issues.contains {
      $0.severity == .error
        && $0.title == "无法读取现有 Markdown 文件"
        && $0.field == "repositoryPath"
    })
    XCTAssertThrowsError(try service.write(preview: preview, rootURL: rootURL)) { error in
      guard case .invalidPreview("content/posts/existing.md")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected invalidPreview, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: destinationURL), invalidUTF8)
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

  func testPreviewDiffCollapsesLongUnchangedRegions() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let destinationURL = rootURL.appendingPathComponent("content/posts/large.md")
    let oldLines = (0..<200).map { "line-\($0)" }
    var newLines = oldLines
    newLines[100] = "changed-line"
    try oldLines.joined(separator: "\n").write(to: destinationURL, atomically: true, encoding: .utf8)
    let package = publishPackage(
      files: [
        .init(
          kind: .markdown,
          repositoryPath: "content/posts/large.md",
          content: newLines.joined(separator: "\n")
        )
      ]
    )

    let preview = LocalPublishPreviewService().preview(package: package, rootURL: rootURL)
    let lineDiff = try XCTUnwrap(preview.fileDiffs.first?.lineDiff)

    XCTAssertTrue(lineDiff.contains("-line-100"))
    XCTAssertTrue(lineDiff.contains("+changed-line"))
    XCTAssertTrue(lineDiff.contains("unchanged line(s)"))
    XCTAssertLessThan(lineDiff.components(separatedBy: "\n").count, 20)
  }

  func testPreviewAsyncMatchesSynchronousPreview() async throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Async Preview",
      slug: "existing",
      draft: false,
      bodyMarkdown: "Updated body that should produce the same preview off the caller's executor."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let service = LocalPublishPreviewService()

    let synchronousPreview = service.preview(package: package, profile: profile)
    let asynchronousPreview = await service.previewAsync(package: package, profile: profile)

    assertEquivalentPreview(asynchronousPreview, synchronousPreview)
  }

  func testPreviewAsyncMatchesSynchronousPreviewForUnsafeAndMissingFiles() async throws {
    let rootURL = try makeRepositoryFixture()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    let package = publishPackage(
      files: [
        .init(kind: .markdown, repositoryPath: "../outside.md", content: "must not escape"),
        .init(
          kind: .image,
          repositoryPath: "images/missing.jpg",
          sourceFilePath: rootURL.appendingPathComponent("does-not-exist.jpg").path
        ),
      ]
    )
    let service = LocalPublishPreviewService()

    let synchronousPreview = service.preview(package: package, profile: profile)
    let asynchronousPreview = await service.previewAsync(package: package, profile: profile)

    assertEquivalentPreview(asynchronousPreview, synchronousPreview)
    XCTAssertEqual(asynchronousPreview.fileDiffs.map(\.status), [.unsafePath, .missingSource])
  }

  func testPreviewAsyncMatchesSynchronousPreviewWhenRepositoryIsMissing() async {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = ""
    profile.localRepositoryBookmarkData = nil
    let package = publishPackage(
      files: [.init(kind: .markdown, repositoryPath: "content/posts/test.md", content: "test")]
    )
    let service = LocalPublishPreviewService()

    let synchronousPreview = service.preview(package: package, profile: profile)
    let asynchronousPreview = await service.previewAsync(package: package, profile: profile)

    assertEquivalentPreview(asynchronousPreview, synchronousPreview)
    XCTAssertEqual(asynchronousPreview.fileDiffs.first?.status, .unsafePath)
    XCTAssertEqual(asynchronousPreview.issues.first?.field, "repository")
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

  func testPathMigrationPreviewAndWriteCreateNewFileAndDeleteOldFile() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Moved Draft",
      slug: "moved-draft",
      draft: false,
      bodyMarkdown: "Updated body for the moved draft lifecycle test.",
      repositoryPath: "content/posts/existing.md",
      repositorySHA: "old-remote-sha"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let service = LocalPublishPreviewService()

    let preview = service.preview(package: package, profile: profile)

    XCTAssertEqual(preview.fileDiffs.map(\.status), [.added, .deleted])
    XCTAssertTrue(preview.fileDiffs[1].lineDiff?.contains("-old content") == true)

    let changedPaths = try service.write(package: package, profile: profile)

    XCTAssertEqual(changedPaths, ["content/posts/moved-draft.md", "content/posts/existing.md"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("content/posts/moved-draft.md").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("content/posts/existing.md").path))
  }

  func testProtectedWriteRejectsExternalModificationAfterPreview() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let destinationURL = rootURL.appendingPathComponent("content/posts/existing.md")
    let package = publishPackage(
      files: [
        .init(
          kind: .markdown,
          repositoryPath: "content/posts/existing.md",
          content: "publisher content"
        )
      ]
    )
    let service = LocalPublishPreviewService()
    let preview = service.preview(package: package, rootURL: rootURL)
    guard case .fileDigest(_)? = preview.fileDiffs.first?.baselineState else {
      return XCTFail("Expected the preview to record the existing file digest")
    }
    try "external editor content".write(to: destinationURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try service.write(preview: preview, rootURL: rootURL)) { error in
      guard case .previewOutdated("content/posts/existing.md")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected previewOutdated, got \(error)")
      }
    }
    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      "external editor content"
    )
  }

  func testProtectedWriteRejectsFileCreatedAfterPreview() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let destinationURL = rootURL.appendingPathComponent("content/posts/new-after-preview.md")
    let package = publishPackage(
      files: [
        .init(
          kind: .markdown,
          repositoryPath: "content/posts/new-after-preview.md",
          content: "publisher content"
        )
      ]
    )
    let service = LocalPublishPreviewService()
    let preview = service.preview(package: package, rootURL: rootURL)
    XCTAssertEqual(preview.fileDiffs.first?.baselineState, .missing)
    try "external new file".write(to: destinationURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try service.write(preview: preview, rootURL: rootURL)) { error in
      guard case .previewOutdated("content/posts/new-after-preview.md")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected previewOutdated, got \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "external new file")
  }

  func testProtectedWriteAcceptsUnchangedPreviewBaseline() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let destinationURL = rootURL.appendingPathComponent("content/posts/existing.md")
    let package = publishPackage(
      files: [
        .init(
          kind: .markdown,
          repositoryPath: "content/posts/existing.md",
          content: "publisher content"
        )
      ]
    )
    let service = LocalPublishPreviewService()
    let preview = service.preview(package: package, rootURL: rootURL)

    XCTAssertEqual(
      try service.write(preview: preview, rootURL: rootURL),
      ["content/posts/existing.md"]
    )
    XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "publisher content")
  }

  func testDeleteOperationRejectsRepositorySymlink() throws {
    let rootURL = try makeRepositoryFixture()
    let outsideURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacDeleteOutside-\(UUID().uuidString).md")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    try "outside content".write(to: outsideURL, atomically: true, encoding: .utf8)
    let linkURL = rootURL.appendingPathComponent("content/posts/delete-link.md")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
    let package = publishPackage(
      files: [
        .init(kind: .markdown, operation: .delete, repositoryPath: "content/posts/delete-link.md")
      ]
    )

    let preview = LocalPublishPreviewService().preview(package: package, rootURL: rootURL)

    XCTAssertEqual(preview.fileDiffs.first?.status, .unsafePath)
    XCTAssertThrowsError(try LocalPublishPreviewService().write(package: package, rootURL: rootURL))
    XCTAssertEqual(try String(contentsOf: outsideURL, encoding: .utf8), "outside content")
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

  func testPreviewMarksIdenticalExistingImageAsUnchanged() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source-cover.jpg")
    let destinationDirectory = rootURL.appendingPathComponent("images", isDirectory: true)
    let destinationURL = destinationDirectory.appendingPathComponent("cover.jpg")
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let imageData = Data("identical image bytes".utf8)
    try imageData.write(to: sourceURL)
    try imageData.write(to: destinationURL)
    let package = publishPackage(
      files: [
        .init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)
      ]
    )

    let preview = LocalPublishPreviewService().preview(package: package, rootURL: rootURL)

    XCTAssertEqual(preview.fileDiffs.first?.status, .unchanged)
    XCTAssertTrue(preview.changedFileDiffs.isEmpty)
  }

  func testMediaPreviewRecordsSourceHashSizeAndFileIdentity() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source-cover.jpg")
    let sourceData = Data("source identity bytes".utf8)
    try sourceData.write(to: sourceURL)
    let package = publishPackage(
      files: [
        .init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)
      ]
    )

    let preview = LocalPublishPreviewService().preview(package: package, rootURL: rootURL)
    let sourceState = try XCTUnwrap(preview.fileDiffs.first?.sourceState)

    XCTAssertEqual(sourceState.byteSize, Int64(sourceData.count))
    XCTAssertEqual(
      sourceState.sha256,
      try BoundedFileReader.sha256(
        at: sourceURL,
        maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
      )
    )
    XCTAssertNotEqual(sourceState.fileIdentifier, 0)
  }

  func testProtectedMediaWriteRejectsSourceContentChangedAfterPreview() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source-cover.jpg")
    try Data("first image bytes".utf8).write(to: sourceURL)
    let package = publishPackage(
      files: [
        .init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)
      ]
    )
    let service = LocalPublishPreviewService()
    let preview = service.preview(package: package, rootURL: rootURL)
    try Data("other image bytes".utf8).write(to: sourceURL)

    XCTAssertThrowsError(try service.write(preview: preview, rootURL: rootURL)) { error in
      guard case .sourcePreviewOutdated("images/cover.jpg")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected sourcePreviewOutdated, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("images/cover.jpg").path))
  }

  func testProtectedMediaWriteRejectsSameBytesFromDifferentFileIdentity() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source-cover.jpg")
    let replacementURL = rootURL.appendingPathComponent("replacement-cover.jpg")
    let sourceData = Data("same image bytes".utf8)
    try sourceData.write(to: sourceURL)
    try sourceData.write(to: replacementURL)
    let package = publishPackage(
      files: [
        .init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)
      ]
    )
    let service = LocalPublishPreviewService()
    let preview = service.preview(package: package, rootURL: rootURL)
    try FileManager.default.removeItem(at: sourceURL)
    try FileManager.default.moveItem(at: replacementURL, to: sourceURL)

    XCTAssertThrowsError(try service.write(preview: preview, rootURL: rootURL)) { error in
      guard case .sourcePreviewOutdated("images/cover.jpg")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected sourcePreviewOutdated, got \(error)")
      }
    }
  }

  func testProtectedMediaWriteRejectsSourceReplacedBySymlinkAfterPreview() throws {
    let rootURL = try makeRepositoryFixture()
    let outsideURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMediaSource-\(UUID().uuidString).jpg")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    let sourceURL = rootURL.appendingPathComponent("source-cover.jpg")
    try Data("preview image bytes".utf8).write(to: sourceURL)
    try Data("outside image bytes".utf8).write(to: outsideURL)
    let package = publishPackage(
      files: [
        .init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)
      ]
    )
    let service = LocalPublishPreviewService()
    let preview = service.preview(package: package, rootURL: rootURL)
    try FileManager.default.removeItem(at: sourceURL)
    try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outsideURL)

    XCTAssertThrowsError(try service.write(preview: preview, rootURL: rootURL)) { error in
      guard case .unsafeSource("images/cover.jpg")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected unsafeSource, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("images/cover.jpg").path))
  }

  func testDirectMediaWriteRejectsSymlinkSource() throws {
    let rootURL = try makeRepositoryFixture()
    let outsideURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherDirectMedia-\(UUID().uuidString).jpg")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    try Data("outside image bytes".utf8).write(to: outsideURL)
    let sourceURL = rootURL.appendingPathComponent("source-link.jpg")
    try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outsideURL)
    let package = publishPackage(
      files: [
        .init(kind: .image, repositoryPath: "images/cover.jpg", sourceFilePath: sourceURL.path)
      ]
    )

    XCTAssertThrowsError(try LocalPublishPreviewService().write(package: package, rootURL: rootURL)) { error in
      guard case .unsafeSource("images/cover.jpg")? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected unsafeSource, got \(error)")
      }
    }
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

  func testWriteRecoversDurableInterruptedTransactionBeforeApplyingNextPublish() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let destinationURL = rootURL.appendingPathComponent("content/posts/existing.md")
    let rollbackDirectory = rootURL.appendingPathComponent(
      ".repopress-local-publish-rollback-fixture",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
    try Data("old content\n".utf8).write(
      to: rollbackDirectory.appendingPathComponent("0-backup")
    )
    try "partially applied content".write(
      to: destinationURL,
      atomically: true,
      encoding: .utf8
    )
    let transaction = [
      "phase": "applying",
      "rollbackDirectoryPath": rollbackDirectory.path,
      "entries": [[
        "repositoryPath": "content/posts/existing.md",
        "backupFileName": "0-backup"
      ]]
    ] as [String: Any]
    let transactionURL = rootURL.appendingPathComponent(
      ".repopress-local-publish-transaction.json"
    )
    try JSONSerialization.data(withJSONObject: transaction, options: [.sortedKeys])
      .write(to: transactionURL, options: .atomic)

    let package = publishPackage(files: [
      .init(
        kind: .markdown,
        repositoryPath: "content/posts/existing.md",
        content: "final published content"
      )
    ])
    try LocalPublishPreviewService().write(package: package, rootURL: rootURL)

    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      "final published content"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: transactionURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackDirectory.path))
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

  func testPreviewAndWriteCopyVideoAsBinaryData() throws {
    let rootURL = try makeRepositoryFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("walkthrough.mp4")
    let videoData = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0xFF, 0x00])
    try videoData.write(to: sourceURL)
    let package = publishPackage(
      files: [
        .init(
          kind: .video,
          repositoryPath: "static/videos/walkthrough.mp4",
          sourceFilePath: sourceURL.path,
          byteSize: Int64(videoData.count)
        )
      ]
    )
    let service = LocalPublishPreviewService()

    let preview = service.preview(package: package, rootURL: rootURL)
    let written = try service.write(package: package, rootURL: rootURL)
    let destinationURL = rootURL.appendingPathComponent("static/videos/walkthrough.mp4")

    XCTAssertEqual(preview.fileDiffs.first?.kind, .video)
    XCTAssertEqual(preview.fileDiffs.first?.status, .added)
    XCTAssertEqual(written, ["static/videos/walkthrough.mp4"])
    XCTAssertEqual(try Data(contentsOf: destinationURL), videoData)
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

  private func assertEquivalentPreview(
    _ actual: LocalPublishPreview,
    _ expected: LocalPublishPreview,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    // Each independently generated preview records its own wall-clock time.
    // Independently constructed issues also receive fresh identity values.
    // Normalize only those generated metadata fields; every semantic field
    // must otherwise match exactly.
    XCTAssertEqual(actual.issues.count, expected.issues.count, file: file, line: line)
    var normalizedActual = actual
    normalizedActual.generatedAt = expected.generatedAt
    for index in normalizedActual.issues.indices where expected.issues.indices.contains(index) {
      normalizedActual.issues[index].id = expected.issues[index].id
    }
    XCTAssertEqual(normalizedActual, expected, file: file, line: line)
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
