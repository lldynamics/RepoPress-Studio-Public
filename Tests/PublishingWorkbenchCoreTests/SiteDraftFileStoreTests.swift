import CryptoKit
import Foundation
import Testing
import XCTest

@testable import PublishingWorkbenchCore

struct SiteDraftFileStoreTests {
  @Test
  func writesOnlySiteDraftMarkdownIntoProject() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    var draft = ArticleDraft.empty(profile: profile)
    draft.title = "实时站点草稿"
    draft.slug = "live-site-draft"
    draft.bodyMarkdown = "项目中的正文"

    let result = try SiteDraftFileStore().write(draft: draft, profile: profile)
    let destinationURL = rootURL.appendingPathComponent(result.repositoryPath)
    let contents = try String(contentsOf: destinationURL, encoding: .utf8)

    #expect(result.repositoryPath == profile.markdownPath(for: draft))
    #expect(contents.contains("实时站点草稿"))
    #expect(contents.contains("项目中的正文"))
  }

  @Test
  func movingMarkdownPathRemovesPreviousFile() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "before"
    let fileStore = SiteDraftFileStore()

    let firstResult = try fileStore.write(draft: draft, profile: profile)
    draft.repositoryPath = firstResult.repositoryPath
    draft.slug = "after"
    draft.bodyMarkdown = "新路径正文"
    let secondResult = try fileStore.write(draft: draft, profile: profile)

    #expect(
      !FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(firstResult.repositoryPath).path
      ))
    #expect(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(secondResult.repositoryPath).path
      ))
  }

  @Test
  func refusesToOverwriteBoundFileChangedByAnotherEditor() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "external-edit"
    draft.bodyMarkdown = "App baseline"
    let fileStore = SiteDraftFileStore()

    let firstResult = try fileStore.write(draft: draft, profile: profile)
    let destinationURL = rootURL.appendingPathComponent(firstResult.repositoryPath)
    let baselineDocument = try String(contentsOf: destinationURL, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: firstResult.repositoryPath,
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(baselineDocument)
    )
    draft.bodyMarkdown = "Pending app edit"
    let externalDocument = "---\ntitle: External editor\n---\n\nExternal content\n"
    try externalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)

    #expect(throws: SiteDraftFileStoreError.projectFileChangedExternally(firstResult.repositoryPath)) {
      try fileStore.write(draft: draft, profile: profile)
    }
    #expect(try String(contentsOf: destinationURL, encoding: .utf8) == externalDocument)
  }

  @Test
  func importedFormattingUsesOriginalFileDigestForFirstEdit() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let repositoryPath = "content/posts/imported-formatting.md"
    let originalDocument = """
    ---
    tags: [Swift, Local]
    slug: imported-formatting
    title: Imported formatting

    ---

    Original body
    """
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try originalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)

    let importer = LocalContentImportService(isContentIndexEnabled: false)
    var draft = try importer.parseProjectDocument(
      originalDocument,
      repositoryPath: repositoryPath,
      rootURL: rootURL,
      profile: profile
    )
    let originalDigest = ArticleDraft.repositoryDocumentDigest(originalDocument)
    #expect(draft.repositoryBinding?.projectFileContentDigest == originalDigest)
    #expect(
      draft.repositoryBinding?.projectFileRenderedContentDigest
        == draft.renderedRepositoryContentDigest(profile: profile)
    )
    #expect(draft.repositoryBinding?.projectFileContentDigest
      != draft.repositoryBinding?.projectFileRenderedContentDigest)

    draft.bodyMarkdown = "Original body\n\nFirst editor change"
    let result = try SiteDraftFileStore().write(draft: draft, profile: profile)

    #expect(result.writtenPaths == [repositoryPath])
    #expect(try String(contentsOf: destinationURL, encoding: .utf8).contains("First editor change"))
  }

  @Test
  func importedDocumentWithRemoteRevisionStillUsesExactLocalBytes() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let path = "content/posts/revision-import.md"
    let document = "---\ntitle: Revision import\nslug: revision-import\n\n---\n\nOriginal body\n"
    let url = rootURL.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.write(to: url, atomically: true, encoding: .utf8)
    let result = LocalContentImportService().importDraft(document: document, repositoryPath: path,
      profile: profile, repositorySHA: String(repeating: "a", count: 40))
    var draft = try #require(result.importedDrafts.first)
    #expect(draft.repositoryBinding?.projectFileContentDigest == ArticleDraft.repositoryDocumentDigest(document))
    draft.bodyMarkdown = "Edited body"
    _ = try SiteDraftFileStore().write(draft: draft, profile: profile)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("Edited body"))
    try "Unreviewed external edit".write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: SiteDraftFileStoreError.projectFileChangedExternally(path)) {
      try SiteDraftFileStore().write(draft: draft, profile: profile)
    }
  }

  @Test
  func exactCurrentDocumentRepairsStaleBaselineWithoutRewriting() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "already-written"
    draft.bodyMarkdown = "The write completed before its baseline was persisted."
    let repositoryPath = profile.markdownPath(for: draft)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    let intendedDocument = FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try intendedDocument.write(to: destinationURL, atomically: true, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: repositoryPath,
      renderedContentDigest: String(repeating: "0", count: 64)
    )

    let result = try SiteDraftFileStore().write(draft: draft, profile: profile)

    #expect(result.repositoryPath == repositoryPath)
    #expect(result.writtenPaths.isEmpty)
    #expect(try String(contentsOf: destinationURL, encoding: .utf8) == intendedDocument)
  }

  @Test
  func refusesPathMoveWhenAnotherFileAlreadyUsesDestination() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try makeGitMarker(at: rootURL)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "before-collision"
    let fileStore = SiteDraftFileStore()

    let firstResult = try fileStore.write(draft: draft, profile: profile)
    let oldURL = rootURL.appendingPathComponent(firstResult.repositoryPath)
    let baselineDocument = try String(contentsOf: oldURL, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: firstResult.repositoryPath,
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(baselineDocument)
    )
    draft.slug = "occupied-destination"
    let destinationPath = profile.markdownPath(for: draft)
    let destinationURL = rootURL.appendingPathComponent(destinationPath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let externalDocument = "Existing destination owned by another tool"
    try externalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)

    #expect(throws: SiteDraftFileStoreError.projectFileChangedExternally(destinationPath)) {
      try fileStore.write(draft: draft, profile: profile)
    }
    #expect(FileManager.default.fileExists(atPath: oldURL.path))
    #expect(try String(contentsOf: destinationURL, encoding: .utf8) == externalDocument)
  }

  @Test
  func neverWritesGeneralDraftIntoProject() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: profile)

    #expect(throws: SiteDraftFileStoreError.generalDraftCannotBeWritten) {
      try SiteDraftFileStore().write(draft: draft, profile: profile)
    }
    let contents = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
    #expect(contents.isEmpty)
  }

  @Test
  func refusesSiteDraftWriteOutsideGitRepository() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "must-not-write"

    #expect(throws: LocalPublishPreviewError.self) {
      try SiteDraftFileStore().write(draft: draft, profile: profile)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(profile.markdownPath(for: draft)).path
      )
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("site-draft-file-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeGitMarker(at rootURL: URL) throws {
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
  }
}

final class ExternalDraftFileWriterTests: XCTestCase {
  func testWritesNestedMarkdownAndReturnsWrittenFingerprint() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = root.appendingPathComponent("drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    let source = drafts.appendingPathComponent("article.md")
    try write("# Before\n", to: source)
    let expected = try fingerprint(of: source)

    let written = try ExternalDraftFileWriter().write(
      rootURL: root,
      relativePath: "drafts/article.md",
      expectedFingerprint: expected,
      markdown: "# After\n"
    )

    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "# After\n")
    XCTAssertEqual(written, try fingerprint(of: source))
  }

  func testConflictLeavesOriginalSourceUntouched() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("article.md")
    try write("original", to: source)

    XCTAssertThrowsError(
      try ExternalDraftFileWriter().write(
        rootURL: root,
        relativePath: "article.md",
        expectedFingerprint: fingerprint(of: Data("different".utf8)),
        markdown: "replacement"
      )
    ) { error in
      guard case .conflict = error as? ExternalDraftFileWriterError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
  }

  func testRejectsTraversalAndSymlinkEscape() throws {
    let root = try makeTemporaryDirectory()
    let outside = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let outsideSource = outside.appendingPathComponent("outside.md")
    try write("outside", to: outsideSource)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape", isDirectory: true),
      withDestinationURL: outside
    )

    for path in ["../outside.md", "escape/outside.md"] {
      XCTAssertThrowsError(
        try ExternalDraftFileWriter().write(
          rootURL: root,
          relativePath: path,
          expectedFingerprint: "unused",
          markdown: "replacement"
        )
      ) { error in
        guard case .invalidRelativePath = error as? ExternalDraftFileWriterError else {
          return XCTFail("Unexpected error for \(path): \(error)")
        }
      }
    }
    XCTAssertEqual(try String(contentsOf: outsideSource, encoding: .utf8), "outside")
  }

  func testMissingSourceIsNeverCreated() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing.md")

    XCTAssertThrowsError(
      try ExternalDraftFileWriter().write(
        rootURL: root,
        relativePath: "missing.md",
        expectedFingerprint: "unused",
        markdown: "replacement"
      )
    ) { error in
      XCTAssertEqual(error as? ExternalDraftFileWriterError, .sourceMissing("missing.md"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testMatchingContentIsIdempotent() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("article.mdx")
    try write("same content", to: source)
    let expected = try fingerprint(of: source)

    let written = try ExternalDraftFileWriter().write(
      rootURL: root,
      relativePath: "article.mdx",
      expectedFingerprint: expected,
      markdown: "same content"
    )

    XCTAssertEqual(written, expected)
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "same content")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "external-draft-file-writer-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func write(_ value: String, to url: URL) throws {
    try value.write(to: url, atomically: true, encoding: .utf8)
  }

  private func fingerprint(of url: URL) throws -> String {
    try fingerprint(of: Data(contentsOf: url))
  }

  private func fingerprint(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
