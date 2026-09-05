import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RepositoryWorktreePublishStoreTests: XCTestCase {
  private struct Fixture {
    let baseURL: URL
    let worktreeURL: URL
    let profile: SiteProfile
    let draft: ArticleDraft
    let articleURL: URL
    let store: WorkbenchStore
  }

  func testPrepareFlushesActiveDirtyEditorBufferBeforeFreezingGitReview() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()

    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id,
        bodyMarkdown: "应当先落盘再进入完整 Git 清单。",
        revision: 1,
        isDirty: true
      ),
      for: fixture.draft.id
    )

    let confirmation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Publish buffered edit"
    )

    let review = try XCTUnwrap(confirmation)
    XCTAssertEqual(review.snapshot.paths, ["content/posts/article.md"])
    XCTAssertTrue(
      try String(contentsOf: fixture.articleURL, encoding: .utf8)
        .contains("应当先落盘再进入完整 Git 清单。")
    )
    XCTAssertFalse(fixture.store.draftBodyEditorBuffer(for: fixture.draft.id).isDirty)
  }

  func testPreparePreservesExternalArticleWhenEditorBufferIsAlsoDirty() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let externalDocument = "+++\ntitle = \"External\"\n+++\n外部编辑器写入的内容。\n"
    try externalDocument.write(to: fixture.articleURL, atomically: true, encoding: .utf8)
    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id,
        bodyMarkdown: "软件内尚未落盘的另一份修改。",
        revision: 1,
        isDirty: true
      ),
      for: fixture.draft.id
    )

    let confirmation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Do not overwrite external edit"
    )

    XCTAssertNil(confirmation)
    XCTAssertEqual(
      try String(contentsOf: fixture.articleURL, encoding: .utf8),
      externalDocument
    )
    XCTAssertTrue(fixture.store.draftBodyEditorBuffer(for: fixture.draft.id).isDirty)
    XCTAssertTrue(fixture.store.publishActionMessage?.contains("外部修改") == true)
  }

  private func makeFixture() throws -> Fixture {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-worktree-store-\(UUID().uuidString)", isDirectory: true)
    let worktreeURL = baseURL.appendingPathComponent("worktree", isDirectory: true)
    let ownerURL = baseURL.appendingPathComponent("owner", isDirectory: true)
    let remoteURL = ownerURL.appendingPathComponent("site.git", isDirectory: true)
    let articleURL = worktreeURL.appendingPathComponent(
      "content/posts/article.md",
      isDirectory: false
    )
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: ownerURL, withIntermediateDirectories: true)

    let profile = SiteProfile(
      name: "Test",
      localRepositoryRootPath: worktreeURL.path,
      repoOwner: "owner",
      repoName: "site",
      branch: "main",
      markdownPathPattern: "content/posts/{slug}.md"
    )
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Article",
      slug: "article",
      bodyMarkdown: "已写入项目的基线内容。"
    )
    let baselineDocument = FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    try baselineDocument.write(to: articleURL, atomically: true, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/article.md",
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(baselineDocument)
    )

    _ = try git(["init", "--bare", "-b", "main", remoteURL.path], at: baseURL)
    _ = try git(["init", "-b", "main"], at: worktreeURL)
    _ = try git(["config", "user.email", "test@example.com"], at: worktreeURL)
    _ = try git(["config", "user.name", "RepoPress Tests"], at: worktreeURL)
    _ = try git(["add", "-A", "--", "."], at: worktreeURL)
    _ = try git(["commit", "-m", "base"], at: worktreeURL)
    _ = try git(["remote", "add", "origin", remoteURL.path], at: worktreeURL)
    _ = try git(["push", "-u", "origin", "main"], at: worktreeURL)

    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion,
      releaseRecords: []
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: baseURL.appendingPathComponent("app-data/workbench.json")
      ),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(snapshot: snapshot)
      )
    )
    return Fixture(
      baseURL: baseURL,
      worktreeURL: worktreeURL,
      profile: profile,
      draft: draft,
      articleURL: articleURL,
      store: store
    )
  }

  @discardableResult
  private func git(_ arguments: [String], at rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let output = String(
      decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let error = String(
      decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryWorktreePublishStoreTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: error]
      )
    }
    return output
  }
}
