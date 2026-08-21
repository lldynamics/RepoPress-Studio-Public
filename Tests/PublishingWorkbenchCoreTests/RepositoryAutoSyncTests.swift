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
    XCTAssertFalse(snapshot.repositoryAutoSyncSettings.autoImportRemoteArticles)
    XCTAssertEqual(snapshot.repositoryAutoSyncState.status, .idle)
    XCTAssertTrue(snapshot.repositoryAutoSyncState.remoteChangedPaths.isEmpty)
  }

  func testLegacyAIChatSnapshotDefaultsToEmptyPersistentConversations() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [draft],
        releaseRecords: []
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["formatVersion"] = 8
    object.removeValue(forKey: "aiConversations")
    object.removeValue(forKey: "activeAIConversationIDsByDraftID")
    object["aiChatSessionsByDraftID"] = [draft.id.uuidString: ["messages": []]]
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertTrue(snapshot.aiConversations.isEmpty)
    XCTAssertTrue(snapshot.activeAIConversationIDsByDraftID.isEmpty)
    let reencoded = try JSONEncoder.workbench.encode(snapshot)
    XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains("aiChatSessionsByDraftID"))
  }

  func testStorePersistsAutoSyncSettings() async throws {
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(
        isEnabled: true,
        intervalMinutes: 25,
        fetchBeforeScan: false,
        autoImportRemoteArticles: true
      )
    )
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertTrue(reloaded.repositoryAutoSyncSettings.isEnabled)
    XCTAssertEqual(reloaded.repositoryAutoSyncSettings.normalizedIntervalMinutes, 25)
    XCTAssertFalse(reloaded.repositoryAutoSyncSettings.fetchBeforeScan)
    XCTAssertTrue(reloaded.repositoryAutoSyncSettings.autoImportRemoteArticles)
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
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertTrue(reloaded.repositoryAutoSyncSettings.isEnabled)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.status, .waitingForRepository)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.lastRunAt, now)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.nextRunAt, now.addingTimeInterval(5 * 60))
    XCTAssertEqual(reloaded.repositoryAutoSyncState.message, "自动检查远端等待本地仓库路径。")
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
      "message": "自动检查远端已扫描：发现 2 个远端待拉取变化。"
    }
    """.data(using: .utf8)!

    let state = try JSONDecoder.workbench.decode(RepositoryAutoSyncState.self, from: data)

    XCTAssertEqual(state.status, .scanned)
    XCTAssertEqual(state.remoteChangedFileCount, 2)
    XCTAssertEqual(state.remoteChangedPaths, [])
    XCTAssertEqual(state.importableRemoteArticleCount, 0)
    XCTAssertEqual(state.nonArticleRemoteChangedFileCount, 0)
    XCTAssertNil(state.lastAutoImportAt)
    XCTAssertEqual(state.lastAutoImportedArticleCount, 0)
    XCTAssertEqual(state.lastAutoImportConflictCount, 0)
    XCTAssertEqual(state.lastAutoImportDeletionCount, 0)
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
      message: "自动检查远端已扫描：发现 2 个远端待拉取变化。"
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

  func testAutomaticRemoteArticleImportNeverDeletesLocalDraft() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Keep Me",
      slug: "keep-me",
      bodyMarkdown: "Local body.",
      repositoryPath: "content/posts/keep-me.md"
    )
    store.setDrafts([draft])

    let summary = store.autoImportRemoteArticleDrafts(
      remoteFiles: [
        RepositoryChangedFile(
          status: "D",
          path: "content/posts/keep-me.md",
          kind: .deleted
        )
      ],
      snapshots: [],
      locallyChangedPaths: []
    )

    XCTAssertEqual(summary.importedCount, 0)
    XCTAssertEqual(summary.deletionPaths, ["content/posts/keep-me.md"])
    XCTAssertEqual(store.drafts, [draft])
  }

  func testAutomaticRemoteArticleImportIncludesPrivateDirectory() throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(persistenceURL.deletingLastPathComponent())
    store.updateActiveProfile(profile)
    let path = "private/posts/remote-secret.md"
    let summary = store.autoImportRemoteArticleDrafts(
      remoteFiles: [
        RepositoryChangedFile(status: "A", path: path, kind: .added)
      ],
      snapshots: [
        RepositoryFileSnapshot(
          refName: "origin/main",
          repositoryPath: path,
          content: """
          +++
          title = "Remote Secret"
          draft = false
          +++

          Private remote body.
          """,
          repositorySHA: "private-sha"
        )
      ],
      locallyChangedPaths: []
    )

    XCTAssertEqual(summary.importedCount, 1)
    let draft = try XCTUnwrap(store.drafts.first { $0.repositoryPath == path })
    XCTAssertEqual(draft.title, "Remote Secret")
    XCTAssertEqual(draft.visibility, .private)
    XCTAssertEqual(draft.repositorySHA, "private-sha")
  }

  func testAutomaticRemoteArticleImportProtectsPendingOrFailedSiteDraftSave() throws {
    let path = "content/posts/2027/save-state-protected.md"
    let remoteDocument = """
      ---
      title: Save State Protected
      date: 2027-01-15T08:00:00Z
      ---

      Local body.
      """

    for saveState in [
      SiteDraftFileSaveState.pending(repositoryPath: path),
      .failed(repositoryPath: path, message: "disk unavailable"),
    ] {
      let persistenceURL = try temporaryPersistenceURL()
      defer {
        try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent())
      }
      let store = WorkbenchStore(
        persistence: WorkbenchPersistence(fileURL: persistenceURL)
      )
      store.updateActiveProfile { profile in
        profile.localRepositoryRootPath = persistenceURL.deletingLastPathComponent().path
        profile.localRepositoryBookmarkData = nil
      }
      let draft = ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "Save State Protected",
        date: Date(timeIntervalSince1970: 1_800_000_000),
        slug: "save-state-protected",
        bodyMarkdown: "Local body.",
        repositoryPath: path,
        repositorySHA: "old-sha"
      )
      var importedBaseline = draft
      importedBaseline.repositoryImportFingerprint = importedBaseline.repositoryContentFingerprint
      store.setDrafts([importedBaseline])
      if case .pending = saveState {
        var locallyEdited = importedBaseline
        // The SHA is repository metadata, so this still exercises the
        // autosave race without making the fingerprint guard the reason for
        // the conflict.
        locallyEdited.repositorySHA = "edited-before-write"
        store.updateDraft(locallyEdited)
        XCTAssertEqual(
          store.siteDraftFileSaveStates[locallyEdited.id],
          .pending(repositoryPath: path)
        )
        // Keep the synthetic race window open without sleeping or letting
        // the delayed fixture write complete during this synchronous check.
        store.cancelSiteDraftFileAutosave(for: locallyEdited.id)
        store.siteDraftFileSaveStates[locallyEdited.id] = saveState
      } else {
        store.siteDraftFileSaveStates[draft.id] = saveState
      }

      let summary = store.autoImportRemoteArticleDrafts(
        remoteFiles: [
          RepositoryChangedFile(status: "M", path: path, kind: .modified)
        ],
        snapshots: [
          RepositoryFileSnapshot(
            refName: "origin/main",
            repositoryPath: path,
            content: remoteDocument,
            repositorySHA: "new-sha"
          )
        ],
        locallyChangedPaths: []
      )

      XCTAssertEqual(summary.importedCount, 0)
      XCTAssertEqual(summary.updatedCount, 0)
      XCTAssertEqual(summary.unchangedCount, 0)
      XCTAssertEqual(summary.conflictPaths, [path])
      XCTAssertEqual(store.drafts.first?.bodyMarkdown, "Local body.")
      XCTAssertEqual(store.siteDraftFileSaveStates[draft.id], saveState)
    }
  }

  func testRepositoryContentFingerprintTracksEditableContentButIgnoresRuntimeIDs() {
    let profileID = UUID()
    let firstAttachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/cover.jpg",
      repositoryPath: "static/images/cover.jpg",
      altText: "Cover"
    )
    var first = ArticleDraft(
      siteProfileID: profileID,
      title: "Fingerprint",
      date: Date(timeIntervalSince1970: 1_800_000_000),
      slug: "fingerprint",
      coverAttachmentID: firstAttachment.id,
      bodyMarkdown: "Body",
      attachments: [firstAttachment],
      repositoryPath: "content/posts/fingerprint.md"
    )
    var secondAttachment = firstAttachment
    secondAttachment.id = UUID()
    var second = first
    second.id = UUID()
    second.coverAttachmentID = secondAttachment.id
    second.attachments = [secondAttachment]
    second.createdAt = second.createdAt.addingTimeInterval(100)
    second.updatedAt = second.updatedAt.addingTimeInterval(100)
    second.repositorySHA = "different-runtime-sha"

    XCTAssertEqual(first.repositoryContentFingerprint, second.repositoryContentFingerprint)

    first.bodyMarkdown = "Locally edited body"
    XCTAssertNotEqual(first.repositoryContentFingerprint, second.repositoryContentFingerprint)
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
    store.updateActiveProfile { profile in
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    await store.rememberRepositoryRootAsync(localURL)
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(
        isEnabled: true,
        intervalMinutes: 5,
        fetchBeforeScan: true,
        autoImportRemoteArticles: true
      )
    )
    let now = Date(timeIntervalSince1970: 1_800_000_456)

    let didRun = await store.runRepositoryAutoSync(now: now)
    XCTAssertTrue(didRun)

    XCTAssertEqual(store.repositoryAutoSyncState.status, .scanned)
    XCTAssertEqual(store.repositoryAutoSyncState.fetchSucceeded, true)
    XCTAssertEqual(store.repositoryAutoSyncState.lastFetchAt, now)
    XCTAssertTrue(store.repositoryAutoSyncState.fetchMessage?.contains("已 fetch origin") == true)
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedPaths, [])
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 0)
    XCTAssertEqual(store.repositoryAutoSyncState.lastAutoImportedArticleCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.lastAutoImportConflictCount, 0)
    let imported = try XCTUnwrap(
      store.drafts.first { $0.repositoryPath == "content/posts/remote.md" }
    )
    XCTAssertEqual(imported.title, "Remote Draft")
    XCTAssertEqual(imported.bodyMarkdown, "Remote body.")
    XCTAssertEqual(imported.repositoryImportFingerprint, imported.repositoryContentFingerprint)

    try """
    ---
    title: Remote Draft Updated
    ---

    New remote body.
    """.write(
      to: contributorURL.appendingPathComponent("content/posts/remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote.md"], rootURL: contributorURL)
    try git(["commit", "-m", "Update remote draft"], rootURL: contributorURL)
    try git(["push", "origin", "main"], rootURL: contributorURL)

    let secondRunAt = now.addingTimeInterval(300)
    let didRunSecondCheck = await store.runRepositoryAutoSync(now: secondRunAt)
    XCTAssertTrue(didRunSecondCheck)
    let automaticallyUpdated = try XCTUnwrap(
      store.drafts.first { $0.repositoryPath == "content/posts/remote.md" }
    )
    XCTAssertEqual(automaticallyUpdated.title, "Remote Draft Updated")
    XCTAssertEqual(automaticallyUpdated.bodyMarkdown, "New remote body.")
    XCTAssertEqual(store.repositoryAutoSyncState.lastAutoImportedArticleCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.lastAutoImportConflictCount, 0)

    var locallyEdited = automaticallyUpdated
    locallyEdited.bodyMarkdown = "Local work must remain."
    store.updateDraft(locallyEdited)
    await store.waitForPendingSiteDraftFileWrites()

    try """
    ---
    title: Remote Draft Final
    ---

    Final remote body.
    """.write(
      to: contributorURL.appendingPathComponent("content/posts/remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote.md"], rootURL: contributorURL)
    try git(["commit", "-m", "Update remote draft again"], rootURL: contributorURL)
    try git(["push", "origin", "main"], rootURL: contributorURL)

    let thirdRunAt = secondRunAt.addingTimeInterval(300)
    let didRunThirdCheck = await store.runRepositoryAutoSync(now: thirdRunAt)
    XCTAssertTrue(didRunThirdCheck)
    await store.waitForPendingSave()
    let retained = try XCTUnwrap(
      store.drafts.first { $0.repositoryPath == "content/posts/remote.md" }
    )
    XCTAssertEqual(retained.bodyMarkdown, "Local work must remain.")
    XCTAssertEqual(store.repositoryAutoSyncState.lastAutoImportedArticleCount, 0)
    XCTAssertEqual(store.repositoryAutoSyncState.lastAutoImportConflictCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedPaths, ["content/posts/remote.md"])
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("保留手动审阅"))
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.repositoryAutoSyncState.status, .scanned)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.fetchSucceeded, true)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.lastFetchAt, thirdRunAt)
    XCTAssertEqual(reloaded.repositoryAutoSyncState.remoteChangedPaths, ["content/posts/remote.md"])
    XCTAssertEqual(reloaded.repositoryAutoSyncState.importableRemoteArticleCount, 1)
    XCTAssertTrue(reloaded.repositoryAutoSyncSettings.autoImportRemoteArticles)
    XCTAssertEqual(
      reloaded.drafts.first { $0.repositoryPath == "content/posts/remote.md" }?.bodyMarkdown,
      "Local work must remain."
    )
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
    XCTAssertFalse(store.repositoryAutoSyncState.message.contains("自动检查远端完成"))
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryAutoSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
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
