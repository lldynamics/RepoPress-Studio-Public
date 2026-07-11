import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class RepositoryAutoSyncTests: XCTestCase {
  func testLegacySnapshotDecodesWithDefaultAutoSyncSettings() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [draft],
        releaseRecords: [],
        repositoryAutoSyncSettings: RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 30)
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "repositoryAutoSyncSettings")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertFalse(snapshot.repositoryAutoSyncSettings.isEnabled)
    XCTAssertEqual(snapshot.repositoryAutoSyncSettings.normalizedIntervalMinutes, 15)
    XCTAssertTrue(snapshot.repositoryAutoSyncSettings.fetchBeforeScan)
    XCTAssertEqual(snapshot.repositoryAutoSyncState.status, .idle)
    XCTAssertTrue(snapshot.repositoryAutoSyncState.remoteChangedPaths.isEmpty)
  }

  func testLegacySnapshotDecodesWithEmptyAIChatSessions() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [draft],
        releaseRecords: [],
        aiChatSessionsByDraftID: [
          draft.id: AIPublishingChatSessionState(
            messages: [AIPublishingChatMessage(role: .user, content: "旧会话")],
            contextMode: .general
          )
        ]
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "aiChatSessionsByDraftID")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertTrue(snapshot.aiChatSessionsByDraftID.isEmpty)
  }

  func testStorePersistsAutoSyncSettings() throws {
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 25, fetchBeforeScan: false)
    )

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertTrue(reloaded.repositoryAutoSyncSettings.isEnabled)
    XCTAssertEqual(reloaded.repositoryAutoSyncSettings.normalizedIntervalMinutes, 25)
    XCTAssertFalse(reloaded.repositoryAutoSyncSettings.fetchBeforeScan)
  }

  func testStorePersistsAutoSyncRunState() async throws {
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    let now = Date(timeIntervalSince1970: 1_800_000_222)
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5)
    )

    let didRun = await store.runRepositoryAutoSync(now: now)
    XCTAssertTrue(didRun)

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertTrue(reloaded.repositoryAutoSyncSettings.isEnabled)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.status, .waitingForRepository)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.lastRunAt, now)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.nextRunAt, now.addingTimeInterval(5 * 60))
    XCTAssertEqual(reloaded.repositoryAutoSyncState.message, "自动同步等待本地仓库路径。")
  }

  func testAutoSyncTickRunsOnlyWhenDue() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5)
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    let didRunAtStart = await store.tickRepositoryAutoSync(now: start)
    XCTAssertTrue(didRunAtStart)
    XCTAssertEqual(store.repositoryAutoSyncState.status, .waitingForRepository)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRunAt, start)

    let didRunBeforeDue = await store.tickRepositoryAutoSync(now: start.addingTimeInterval(60))
    XCTAssertFalse(didRunBeforeDue)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRunAt, start)

    let due = start.addingTimeInterval(TimeInterval(RepositoryAutoSyncSettings.minimumIntervalMinutes * 60))
    let didRunWhenDue = await store.tickRepositoryAutoSync(now: due)
    XCTAssertTrue(didRunWhenDue)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRunAt, due)
  }

  func testAutoSyncStateDecodesLegacyPayloadWithoutRemoteChangedPaths() throws {
    let data = """
    {
      "status": "scanned",
      "remoteChangedFileCount": 2,
      "message": "自动同步已扫描：发现 2 个远端待拉取变化。"
    }
    """.data(using: .utf8)!

    let state = try JSONDecoder.workbench.decode(RepositoryAutoSyncState.self, from: data)

    XCTAssertEqual(state.status, .scanned)
    XCTAssertEqual(state.remoteChangedFileCount, 2)
    XCTAssertEqual(state.remoteChangedPaths, [])
    XCTAssertEqual(state.importableRemoteArticleCount, 0)
    XCTAssertEqual(state.nonArticleRemoteChangedFileCount, 0)
  }

  func testAutoSyncStatePersistsRemoteChangedPathQueue() throws {
    let state = RepositoryAutoSyncState(
      status: .scanned,
      remoteChangedFileCount: 2,
      remoteChangedPaths: [
        "content/posts/remote-one.md",
        "static/images/cover.png"
      ],
      importableRemoteArticleCount: 1,
      nonArticleRemoteChangedFileCount: 1,
      lastFetchAt: Date(timeIntervalSince1970: 1_800_000_123),
      fetchSucceeded: true,
      fetchMessage: "已 fetch origin，upstream origin/main 已刷新。",
      message: "自动同步已扫描：发现 2 个远端待拉取变化。"
    )

    let reloaded = try JSONDecoder.workbench.decode(
      RepositoryAutoSyncState.self,
      from: try JSONEncoder.workbench.encode(state)
    )

    XCTAssertEqual(reloaded.remoteChangedPaths, [
      "content/posts/remote-one.md",
      "static/images/cover.png"
    ])
    XCTAssertEqual(reloaded.importableRemoteArticleCount, 1)
    XCTAssertEqual(reloaded.nonArticleRemoteChangedFileCount, 1)
    XCTAssertEqual(reloaded.lastFetchAt, Date(timeIntervalSince1970: 1_800_000_123))
    XCTAssertEqual(reloaded.fetchSucceeded, true)
    XCTAssertEqual(reloaded.fetchMessage, "已 fetch origin，upstream origin/main 已刷新。")
  }

  func testAutoSyncReviewMarkdownExplainsDisabledState() {
    let markdown = RepositoryAutoSyncReviewService().markdown(
      settings: RepositoryAutoSyncSettings(isEnabled: false),
      state: .idle,
      report: nil,
      profile: .defaultProfile
    )

    XCTAssertTrue(markdown.contains("# 远端自动同步审阅"))
    XCTAssertTrue(markdown.contains("- 状态：已关闭"))
    XCTAssertTrue(markdown.contains("- 仓库：未扫描"))
    XCTAssertTrue(markdown.contains("- 打开自动同步后再生成远端变更队列。"))
  }

  func testAutoSyncReviewMarkdownBuildsRemoteChangeQueueAndActions() {
    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content/posts"
    profile.assetRoot = "static/images"
    let state = RepositoryAutoSyncState(
      status: .scanned,
      lastRunAt: Date(timeIntervalSince1970: 1_800_000_000),
      nextRunAt: Date(timeIntervalSince1970: 1_800_000_300),
      remoteChangedFileCount: 3,
      remoteChangedPaths: [
        "content/posts/remote.md",
        "static/images/cover.jpg",
        "config.toml",
      ],
      importableRemoteArticleCount: 1,
      nonArticleRemoteChangedFileCount: 2,
      lastFetchAt: Date(timeIntervalSince1970: 1_800_000_000),
      fetchSucceeded: true,
      fetchMessage: "已 fetch origin，upstream origin/main 已刷新。",
      message: "自动同步已扫描：发现 3 个远端待拉取变化，其中 1 篇文章可导入。"
    )
    let report = autoSyncReport(
      branchStatus: RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main"
      ),
      remoteChangedFiles: [
        RepositoryChangedFile(status: "A", path: "content/posts/remote.md", kind: .added),
        RepositoryChangedFile(status: "M", path: "static/images/cover.jpg", kind: .modified),
        RepositoryChangedFile(status: "M", path: "config.toml", kind: .modified),
      ]
    )

    let markdown = RepositoryAutoSyncReviewService().markdown(
      settings: RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5, fetchBeforeScan: true),
      state: state,
      report: report,
      profile: profile
    )

    XCTAssertTrue(markdown.contains("- 状态：已扫描"))
    XCTAssertTrue(markdown.contains("- 上次扫描：2027-01-15T08:00:00Z"))
    XCTAssertTrue(markdown.contains("- Fetch：成功，已 fetch origin"))
    XCTAssertTrue(markdown.contains("- Upstream：origin/main"))
    XCTAssertTrue(markdown.contains("- 先导入 1 篇远端文章草稿，再处理本地发布。"))
    XCTAssertTrue(markdown.contains("- 审阅图片或配置变更，确认不会影响站点构建和社交预览。"))
    XCTAssertTrue(markdown.contains("### 文章变更（1）"))
    XCTAssertTrue(markdown.contains("- 新增：content/posts/remote.md"))
    XCTAssertTrue(markdown.contains("### 图片变更（1）"))
    XCTAssertTrue(markdown.contains("- 修改：static/images/cover.jpg"))
    XCTAssertTrue(markdown.contains("### 配置变更（1）"))
    XCTAssertTrue(markdown.contains("- 修改：config.toml"))
  }

  func testAutoSyncFetchesUpstreamBeforeScanningRemoteChanges() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryAutoSyncGitTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let remoteURL = rootURL.appendingPathComponent("remote.git", isDirectory: true)
    let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
    let contributorURL = rootURL.appendingPathComponent("contributor", isDirectory: true)

    try git(["init", "--bare", "--initial-branch=main", remoteURL.path], rootURL: rootURL)
    try git(["clone", remoteURL.path, "local"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: localURL)
    try git(["config", "user.name", "Tests"], rootURL: localURL)
    try "base\n".write(to: localURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: localURL)
    try git(["commit", "-m", "Initial"], rootURL: localURL)
    try git(["push", "-u", "origin", "main"], rootURL: localURL)

    try git(["clone", remoteURL.path, "contributor"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: contributorURL)
    try git(["config", "user.name", "Tests"], rootURL: contributorURL)
    try FileManager.default.createDirectory(
      at: contributorURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    ---
    title: Remote Draft
    ---

    Remote body.
    """.write(
      to: contributorURL.appendingPathComponent("content/posts/remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote.md"], rootURL: contributorURL)
    try git(["commit", "-m", "Remote draft"], rootURL: contributorURL)
    try git(["push", "origin", "main"], rootURL: contributorURL)

    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    await store.rememberRepositoryRootAsync(localURL)
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5, fetchBeforeScan: true)
    )
    let now = Date(timeIntervalSince1970: 1_800_000_456)

    let didRun = await store.runRepositoryAutoSync(now: now)
    XCTAssertTrue(didRun)

    XCTAssertEqual(store.repositoryAutoSyncState.status, .scanned)
    XCTAssertEqual(store.repositoryAutoSyncState.fetchSucceeded, true)
    XCTAssertEqual(store.repositoryAutoSyncState.lastFetchAt, now)
    XCTAssertTrue(store.repositoryAutoSyncState.fetchMessage?.contains("已 fetch origin") == true)
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedPaths, ["content/posts/remote.md"])
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 1)

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.repositoryAutoSyncState.status, .scanned)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.fetchSucceeded, true)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.lastFetchAt, now)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.remoteChangedPaths, ["content/posts/remote.md"])
    XCTAssertEqual(reloaded.repositoryAutoSyncState.importableRemoteArticleCount, 1)
  }

  func testAutoSyncReportsFetchFailureInsteadOfClaimingScanCompleted() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryAutoSyncFetchFailure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try git(["init", "--initial-branch=main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    try git(["remote", "add", "origin", rootURL.appendingPathComponent("missing.git").path], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    await store.rememberRepositoryRootAsync(rootURL)
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5, fetchBeforeScan: true)
    )
    let now = Date(timeIntervalSince1970: 1_800_000_789)

    let didRun = await store.runRepositoryAutoSync(now: now)

    XCTAssertTrue(didRun)
    XCTAssertEqual(store.repositoryAutoSyncState.status, .fetchFailed)
    XCTAssertEqual(store.repositoryAutoSyncState.fetchSucceeded, false)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRunAt, now)
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("Fetch 失败"))
    XCTAssertFalse(store.repositoryAutoSyncState.message.contains("自动同步完成"))
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryAutoSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func autoSyncReport(
    branchStatus: RepositoryBranchStatus?,
    remoteChangedFiles: [RepositoryChangedFile]
  ) -> RepositoryScanReport {
    RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      branchStatus: branchStatus,
      changedFiles: [],
      remoteChangedFiles: remoteChangedFiles,
      preflightIssues: [],
      scannedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryAutoSyncTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
