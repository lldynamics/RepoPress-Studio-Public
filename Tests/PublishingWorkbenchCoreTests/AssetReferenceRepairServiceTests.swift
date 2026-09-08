import XCTest

@testable import PublishingWorkbenchCore

final class AssetReferenceRepairServiceTests: XCTestCase {
  func testRepairsSpecialFilenamesInMarkdownAndHTMLAndRescansAsReferenced() throws {
    let contexts = [
      ("![image](", "/images/missing.png", ")"),
      ("![image](<", "../static/images/missing.png", ">)"),
      ("<img src=\"", "/images/missing.png", "\">"),
      ("<img src='", "../static/images/missing.png", "'>"),
    ]
    for (prefix, oldPath, suffix) in contexts {
      let root = try temporaryDirectory()
      let images = root.appendingPathComponent("static/images", isDirectory: true)
      let content = root.appendingPathComponent("content", isDirectory: true)
      try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
      let filename = "new photo (1)#2?3% \"'.png"
      try Data([1]).write(to: images.appendingPathComponent(filename))
      let urlSuffix = "?download=1#preview"
      let body = prefix + oldPath + urlSuffix + suffix
      let source = "---\ntitle: Article\n---\n" + body
      let sourceURL = content.appendingPathComponent("post.md")
      try source.write(to: sourceURL, atomically: true, encoding: .utf8)
      var profile = SiteProfile.defaultProfile
      profile.localRepositoryRootPath = root.path
      var draft = ArticleDraft(siteProfileID: profile.id, title: "Article", bodyMarkdown: body)
      draft.recordProjectFile(
        profile: profile, repositoryPath: "content/post.md",
        renderedContentDigest: ArticleDraft.repositoryDocumentDigest(source))
      let scanner = AssetResourceManagerService()
      let report = try scanner.scan(repositoryRootURL: root, assetRoot: "static", profileID: profile.id)
      let reference = try XCTUnwrap(report.brokenReferences.first)
      let replacement = try XCTUnwrap(report.assets.first)
      let service = AssetReferenceRepairService()
      let preview = try service.makePreview(
        reference: reference, replacement: replacement, report: report, drafts: [draft])
      let updated = try service.applying(preview, to: draft)
      XCTAssertTrue(updated.bodyMarkdown.hasSuffix(urlSuffix + suffix))
      try updated.bodyMarkdown.write(to: sourceURL, atomically: true, encoding: .utf8)

      let repaired = try scanner.scan(repositoryRootURL: root, assetRoot: "static", profileID: profile.id)
      XCTAssertTrue(repaired.brokenReferences.isEmpty, updated.bodyMarkdown)
      XCTAssertEqual(repaired.assets.first?.references.count, 1, updated.bodyMarkdown)
      XCTAssertTrue(repaired.orphanedAssets.isEmpty)
    }
  }

  func testPreviewReplacesOnlyCapturedTokenAndRejectsCodeAndStaleBodies() throws {
    let root = try temporaryDirectory()
    let assetRoot = root.appendingPathComponent("static/images", isDirectory: true)
    try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
    let replacementURL = assetRoot.appendingPathComponent("new.png")
    try Data([1]).write(to: replacementURL)
    let body = "![one](/images/missing.png)\n```md\n![code](/images/missing.png)\n```"
    let source = "---\ntitle: Article\n---\n" + body
    let sourceURL = root.appendingPathComponent("content/post.md")
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = root.path
    var draft = ArticleDraft(siteProfileID: profile.id, title: "文章", bodyMarkdown: body)
    draft.recordProjectFile(
      profile: profile, repositoryPath: "content/post.md",
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(source)
    )
    let firstRange = (source as NSString).range(of: "/images/missing.png")
    let reference = AssetResourceBrokenReference(
      sourceMarkdownPath: "content/post.md", lineNumber: 1, rawPath: "/images/missing.png",
      tokenUTF16Location: firstRange.location, tokenUTF16Length: firstRange.length,
      kind: .missing, message: "missing")
    let asset = AssetResourceItem(
      repositoryPath: "static/images/new.png", absoluteFilePath: replacementURL.path,
      filename: "new.png",
      fileExtension: "PNG", kind: .image, byteSize: 1, modifiedAt: nil, dimensions: nil,
      references: [], canCompress: false)
    let report = AssetResourceScanReport(
      profileID: profile.id, repositoryRootPath: root.path, assetRootPath: "static",
      assets: [asset],
      brokenReferences: [reference], scannedMarkdownFileCount: 1)
    let service = AssetReferenceRepairService()
    let editorLocation = try service.editorLocation(for: reference, report: report, drafts: [draft])
    XCTAssertEqual(editorLocation.draftID, draft.id)
    XCTAssertEqual(
      editorLocation.selectedRange,
      NSRange(
        location: firstRange.location - (source as NSString).range(of: body).location,
        length: firstRange.length))
    let preview = try service.makePreview(
      reference: reference, replacement: asset, report: report, drafts: [draft])
    let updated = try service.applying(preview, to: draft)

    XCTAssertTrue(updated.bodyMarkdown.contains("![one](/images/new.png)"))
    XCTAssertTrue(updated.bodyMarkdown.contains("![code](/images/missing.png)"))
    var stale = draft
    stale.bodyMarkdown += "\nchanged"
    XCTAssertThrowsError(try service.applying(preview, to: stale)) { error in
      XCTAssertEqual(error as? AssetReferenceRepairError, .stalePreview)
    }
    try (source + "\nexternal").write(to: sourceURL, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try service.validatePreviewDiskBaseline(preview, report: report)) {
      error in
      XCTAssertEqual(error as? AssetReferenceRepairError, .stalePreview)
    }
  }

  func testPreviewRejectsUnmappedDraftAndEscapedReplacement() throws {
    let root = try temporaryDirectory()
    let reference = AssetResourceBrokenReference(
      sourceMarkdownPath: "content/unmapped.md", lineNumber: 1, rawPath: "/images/missing.png",
      tokenUTF16Location: 0, tokenUTF16Length: 19, kind: .missing, message: "missing")
    let asset = AssetResourceItem(
      repositoryPath: "static/images/escape.png",
      absoluteFilePath: root.appendingPathComponent("escape.png").path,
      filename: "escape.png", fileExtension: "PNG", kind: .image, byteSize: 1, modifiedAt: nil,
      dimensions: nil, references: [], canCompress: false)
    let report = AssetResourceScanReport(
      profileID: UUID(), repositoryRootPath: root.path, assetRootPath: "static", assets: [asset],
      brokenReferences: [reference], scannedMarkdownFileCount: 1)
    XCTAssertThrowsError(
      try AssetReferenceRepairService().makePreview(
        reference: reference, replacement: asset, report: report, drafts: []
      )
    ) { error in
      XCTAssertEqual(error as? AssetReferenceRepairError, .unavailableDraft)
    }
  }

  func testRepeatedPathLocationsRemainDistinctRepairTargets() {
    let first = AssetResourceBrokenReference(
      sourceMarkdownPath: "content/post.md", lineNumber: 3, rawPath: "/images/missing.png",
      tokenUTF16Location: 20, tokenUTF16Length: 19, kind: .missing, message: "missing")
    let second = AssetResourceBrokenReference(
      sourceMarkdownPath: "content/post.md", lineNumber: 3, rawPath: "/images/missing.png",
      tokenUTF16Location: 60, tokenUTF16Length: 19, kind: .missing, message: "missing")
    XCTAssertNotEqual(first.id, second.id)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "AssetReferenceRepairServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
