import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishingImportTests: WorkbenchStoreRemotePublishingTestCase {
  func testImportsRemoteArticleDraftFromUpstreamSnapshot() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(
      to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try """
    ---
    title: "Remote Draft"
    slug: remote-draft
    description: "Imported from upstream."
    ---

    Remote body for review.
    """.write(
      to: rootURL.appendingPathComponent("content/posts/remote-draft.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote-draft.md"], rootURL: rootURL)
    try git(["commit", "-m", "Remote draft"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    let remoteBlobSHA = try git(
      ["rev-parse", "\(remoteCommit):content/posts/remote-draft.md"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    await store.scanRepositoryAsync()

    let summary = await store.importRemoteDraftFromRepository(
      repositoryPath: "content/posts/remote-draft.md")

    XCTAssertEqual(summary.insertedCount, 1)
    XCTAssertEqual(summary.updatedCount, 0)
    let imported = try XCTUnwrap(
      store.drafts.first { $0.repositoryPath == "content/posts/remote-draft.md" })
    XCTAssertEqual(imported.title, "Remote Draft")
    XCTAssertEqual(imported.summary, "Imported from upstream.")
    XCTAssertEqual(imported.bodyMarkdown, "Remote body for review.")
    XCTAssertEqual(imported.repositorySHA, remoteBlobSHA)
    XCTAssertEqual(store.selectedDraftID, imported.id)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(
      store.publishActionMessage, "已从 origin/main 导入远端文章 content/posts/remote-draft.md。")
  }

  func testImportsRemoteChangedArticleDraftsFromUpstreamQueue() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(
      to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try "remote readme\n".write(
      to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try remoteArticle(title: "Remote One", slug: "remote-one", body: "Remote one body.")
      .write(
        to: rootURL.appendingPathComponent("content/posts/remote-one.md"),
        atomically: true,
        encoding: .utf8
      )
    try remoteArticle(title: "Remote Two", slug: "remote-two", body: "Remote two body.")
      .write(
        to: rootURL.appendingPathComponent("content/posts/remote-two.md"),
        atomically: true,
        encoding: .utf8
      )
    try git(
      ["add", "README.md", "content/posts/remote-one.md", "content/posts/remote-two.md"],
      rootURL: rootURL)
    try git(["commit", "-m", "Remote drafts"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    await store.scanRepositoryAsync()
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5, fetchBeforeScan: false)
    )
    await store.runRepositoryAutoSync(now: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedFileCount, 3)
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 2)
    XCTAssertEqual(store.repositoryAutoSyncState.nonArticleRemoteChangedFileCount, 1)
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("其中 2 个文章候选路径可手动尝试导入"))

    let summary = await store.importRemoteChangedArticleDraftsFromRepository()

    XCTAssertEqual(summary.insertedCount, 2)
    XCTAssertEqual(summary.updatedCount, 0)
    XCTAssertTrue(
      store.drafts.contains {
        $0.repositoryPath == "content/posts/remote-one.md" && $0.title == "Remote One"
      })
    XCTAssertTrue(
      store.drafts.contains {
        $0.repositoryPath == "content/posts/remote-two.md" && $0.title == "Remote Two"
      })
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.publishActionMessage, "已从远端文章变更导入 2 篇、更新 0 篇。")
  }

  #if DEBUG
    func testRemoteImportReportsSkippedCandidateWhenSlugDoesNotRoundTrip() async throws {
      let rootURL = try temporaryDirectoryURL()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      try FileManager.default.createDirectory(
        at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
        withIntermediateDirectories: true
      )
      let store = try TestWorkbenchFactory.makeStore()
      var profile = store.activeProfile
      profile.rememberLocalRepositoryRoot(rootURL)
      profile.contentRoot = "content"
      profile.markdownPathPattern = "content/posts/{slug}.md"
      store.updateActiveProfile(profile)
      store.repositoryStore.remoteFileSnapshotTestOverride = {
        RepositoryFileSnapshot(
          refName: "origin/main",
          repositoryPath: "content/posts/wrong-name.md",
          content: """
            ---
            title: "Wrong Name"
            slug: expected-name
            ---

            Body
            """
        )
      }
      defer { store.repositoryStore.remoteFileSnapshotTestOverride = nil }

      let summary = await store.importRemoteDraftFromRepository(
        repositoryPath: "content/posts/wrong-name.md"
      )

      XCTAssertEqual(summary.changedCount, 0)
      XCTAssertGreaterThan(summary.skippedCount, 0)
      let message = try XCTUnwrap(store.publishActionMessage)
      XCTAssertTrue(message.contains("已跳过候选文件"), "实际消息：\(message)")
      XCTAssertTrue(
        message.contains("文章路径与当前站点发布规则不一致"),
        "实际消息：\(message)"
      )
    }
  #endif

  #if DEBUG
    func testRemoteArticleImportDropsResultWhenActiveProfileChangesDuringSnapshot() async throws {
      let rootURL = try preparedGitRepositoryRoot()
      defer { try? FileManager.default.removeItem(at: rootURL) }

      try git(["switch", "-c", "remote-work"], rootURL: rootURL)
      try remoteArticle(title: "Remote Draft", slug: "remote-draft", body: "Remote body.")
        .write(
          to: rootURL.appendingPathComponent("content/posts/remote-draft.md"),
          atomically: true,
          encoding: .utf8
        )
      try git(["add", "content/posts/remote-draft.md"], rootURL: rootURL)
      try git(["commit", "-m", "Remote draft"], rootURL: rootURL)
      let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
      try git(["switch", "main"], rootURL: rootURL)
      try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
      try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
      try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
      try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

      let store = try TestWorkbenchFactory.makeStore()
      var profile = store.activeProfile
      profile.rememberLocalRepositoryRoot(rootURL)
      profile.contentRoot = "content"
      store.updateActiveProfile(profile)
      let originalProfileID = profile.id
      let secondaryProfile = store.createProfile(named: "Secondary")
      store.selectProfile(originalProfileID)

      let gate = RemoteImportTestGate()
      store.repositoryStore.remoteFileSnapshotTestHook = {
        await gate.waitUntilEntered()
      }
      let importTask = Task { @MainActor in
        await store.importRemoteDraftFromRepository(
          repositoryPath: "content/posts/remote-draft.md"
        )
      }
      for _ in 0..<20 {
        if await gate.hasEntered() { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      let didEnterSnapshotWork = await gate.hasEntered()
      XCTAssertTrue(didEnterSnapshotWork)

      store.selectProfile(secondaryProfile.id)
      await gate.release()
      let summary = await importTask.value
      store.repositoryStore.remoteFileSnapshotTestHook = nil

      XCTAssertEqual(summary.changedCount, 0)
      XCTAssertFalse(store.drafts.contains { $0.repositoryPath == "content/posts/remote-draft.md" })
      XCTAssertEqual(store.activeProfileID, secondaryProfile.id)
      XCTAssertEqual(store.publishActionMessage, "当前站点已变化，未导入原站点远端文章。")
    }
  #endif
}
