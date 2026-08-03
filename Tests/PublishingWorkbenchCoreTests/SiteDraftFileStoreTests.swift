import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct SiteDraftFileStoreTests {
  @Test
  func writesOnlySiteDraftMarkdownIntoProject() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.localRepositoryBookmarkData = nil
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
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.localRepositoryBookmarkData = nil
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
  func neverWritesGeneralDraftIntoProject() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.localRepositoryBookmarkData = nil
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: profile)

    #expect(throws: SiteDraftFileStoreError.generalDraftCannotBeWritten) {
      try SiteDraftFileStore().write(draft: draft, profile: profile)
    }
    let contents = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
    #expect(contents.isEmpty)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("site-draft-file-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
