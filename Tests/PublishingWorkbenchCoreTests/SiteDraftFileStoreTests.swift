import Foundation
import Testing

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
