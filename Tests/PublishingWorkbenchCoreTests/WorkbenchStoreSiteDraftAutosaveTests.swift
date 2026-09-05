import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreSiteDraftAutosaveTests: XCTestCase {
  private struct PersistedSiteDraftFixture {
    let draft: ArticleDraft
    let profile: SiteProfile
    let snapshot: WorkbenchSnapshot
    let destinationURL: URL
  }

  func testCreatedSiteDraftStaysLocalUntilExplicitlyAddedThenAutosaves() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-project")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistenceURL = rootURL.appendingPathComponent("app-data/workbench.json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
    }
    await store.waitForPendingSiteDraftFileWrites()

    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "实时保存验收"
    draft.slug = "live-save-acceptance"
    draft.bodyMarkdown = "第一版正文"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()

    draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertNil(draft.repositoryPath)
    XCTAssertNil(draft.repositoryBinding)
    XCTAssertNil(store.siteDraftFileSaveStates[draft.id])
    XCTAssertTrue(try markdownProjectFiles(in: rootURL).isEmpty)

    let didAddToProject = await store.writeSiteDraftToProject(draftID: draft.id)
    XCTAssertTrue(didAddToProject)
    await store.waitForPendingSiteDraftFileWrites()

    draft = try XCTUnwrap(store.selectedDraft)
    let repositoryPath = try XCTUnwrap(draft.repositoryPath)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    var contents = try String(contentsOf: destinationURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("第一版正文"))
    XCTAssertEqual(draft.repositoryBinding?.repositoryPath, repositoryPath)
    XCTAssertEqual(
      draft.repositoryBinding?.renderedContentDigest,
      draft.renderedRepositoryContentDigest(profile: store.activeProfile)
    )
    XCTAssertEqual(
      store.siteDraftFileSaveStates[draft.id],
      .saved(
        repositoryPath: repositoryPath,
        savedAt: store.siteDraftFileSaveStates[draft.id]?.savedAtForTesting ?? .distantPast)
    )

    draft.bodyMarkdown = "第二版正文"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()
    contents = try String(contentsOf: destinationURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("第二版正文"))
    XCTAssertFalse(contents.contains("第一版正文"))
  }

  func testPublicLocalWriteMaterializesLocalFirstDraftAndEnablesAutosave() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-public-local-write")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")
      )
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }

    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "公开本地写入"
    draft.slug = "public-local-write"
    draft.bodyMarkdown = "第一版通过发布抽屉的保存到本地动作写入。"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()
    XCTAssertNil(store.selectedDraft?.repositoryPath)

    let result = await store.writeSelectedDraftToLocalRepository()
    guard case .succeeded = result else {
      return XCTFail("Expected local write success, got \(result)")
    }

    draft = try XCTUnwrap(store.selectedDraft)
    let repositoryPath = try XCTUnwrap(draft.repositoryPath)
    XCTAssertEqual(draft.repositoryBinding?.repositoryPath, repositoryPath)
    XCTAssertEqual(draft.repositorySyncState(for: store.activeProfile), .projectSaved)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))

    draft.bodyMarkdown = "第二版已经启用项目文件自动保存。"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()
    let contents = try String(contentsOf: destinationURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("第二版已经启用项目文件自动保存。"))
    XCTAssertFalse(contents.contains("第一版通过发布抽屉"))
  }

  func testDebouncedAutosavePreservesExternalEditMadeBeforePreview() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-external-edit-during-debounce")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")
      )
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }

    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "External edit debounce"
    draft.slug = "external-edit-debounce"
    draft.bodyMarkdown = "Initial app content"
    store.updateDraft(draft)
    let didAddToProject = await store.writeSiteDraftToProject(draftID: draft.id)
    XCTAssertTrue(didAddToProject)
    await store.waitForPendingSiteDraftFileWrites()

    draft = try XCTUnwrap(store.selectedDraft)
    let repositoryPath = try XCTUnwrap(draft.repositoryPath)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    draft.bodyMarkdown = "Pending app content"
    store.updateDraft(draft)

    // This write intentionally lands inside the 350 ms debounce window,
    // before SiteDraftFileStore generates its preview.
    let externalDocument = "---\ntitle: External version\n---\n\nExternal editor content\n"
    try externalDocument.write(to: destinationURL, atomically: true, encoding: .utf8)
    await store.waitForPendingSiteDraftFileWrites()

    XCTAssertEqual(
      try String(contentsOf: destinationURL, encoding: .utf8),
      externalDocument
    )
    guard case .failed(let failedPath, let message) = store.siteDraftFileSaveStates[draft.id] else {
      return XCTFail("Expected autosave to fail closed after the external edit")
    }
    XCTAssertEqual(failedPath, repositoryPath)
    XCTAssertTrue(message.contains("其他软件或 Git 修改"))
    XCTAssertTrue(store.publishActionMessage?.contains("其他软件或 Git 修改") == true)
  }

  func testRestartWithUnchangedBoundDraftSkipsWriteAndStateChurn() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-unchanged-restart")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistenceURL = rootURL.appendingPathComponent("app-data/workbench.json")
    let fixture = try makePersistedSiteDraft(
      rootURL: rootURL,
      bodyMarkdown: "重启后内容保持不变"
    )
    let sentinelDate = Date(timeIntervalSince1970: 1_234_567_890)
    try FileManager.default.setAttributes(
      [.modificationDate: sentinelDate],
      ofItemAtPath: fixture.destinationURL.path
    )
    let fileDateBeforeRestart = try modificationDate(for: fixture.destinationURL)

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(snapshot: fixture.snapshot)
      )
    )
    var draftPublications = 0
    let draftPublication = store.publishingStore.$drafts
      .dropFirst()
      .sink { _ in draftPublications += 1 }
    defer { draftPublication.cancel() }
    let draftBeforeRestart = try XCTUnwrap(
      store.drafts.first(where: { $0.id == fixture.draft.id })
    )
    XCTAssertEqual(
      draftBeforeRestart.repositoryBinding?.projectFileContentDigest,
      draftBeforeRestart.renderedRepositoryContentDigest(profile: store.activeProfile)
    )
    let saveStatusBeforeRestart = store.lastSaveStatus
    let hadUnsavedChangesBeforeReconciliation = store.hasUnsavedChanges

    await store.waitForPendingSiteDraftFileWrites()
    await store.waitForPendingSave()

    let draftAfterRestart = try XCTUnwrap(
      store.drafts.first(where: { $0.id == fixture.draft.id })
    )
    XCTAssertEqual(draftAfterRestart, draftBeforeRestart)
    XCTAssertEqual(draftAfterRestart.updatedAt, draftBeforeRestart.updatedAt)
    XCTAssertEqual(draftAfterRestart.repositoryBinding, draftBeforeRestart.repositoryBinding)
    XCTAssertNil(store.siteDraftFileSaveStates[fixture.draft.id])
    XCTAssertEqual(store.hasUnsavedChanges, hadUnsavedChangesBeforeReconciliation)
    XCTAssertEqual(store.lastSaveStatus, saveStatusBeforeRestart)
    XCTAssertEqual(try modificationDate(for: fixture.destinationURL), fileDateBeforeRestart)
    XCTAssertEqual(draftPublications, 0)
  }

  func testRestartWithStaleProjectDigestRewritesAndRefreshesBinding() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-stale-restart")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistenceURL = rootURL.appendingPathComponent("app-data/workbench.json")
    let fixture = try makePersistedSiteDraft(
      rootURL: rootURL,
      bodyMarkdown: "旧的项目文件内容"
    )
    let sentinelDate = Date(timeIntervalSince1970: 1_234_567_890)
    try FileManager.default.setAttributes(
      [.modificationDate: sentinelDate],
      ofItemAtPath: fixture.destinationURL.path
    )

    var staleDraft = fixture.draft
    staleDraft.bodyMarkdown = "重启后需要补写的新内容"
    let staleSnapshot = WorkbenchSnapshot(
      profiles: [fixture.profile],
      activeProfileID: fixture.profile.id,
      drafts: [staleDraft],
      softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion,
      releaseRecords: []
    )

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(snapshot: staleSnapshot)
      )
    )
    var draftPublications = 0
    let draftPublication = store.publishingStore.$drafts
      .dropFirst()
      .sink { _ in draftPublications += 1 }
    defer { draftPublication.cancel() }

    await store.waitForPendingSiteDraftFileWrites()
    await store.waitForPendingSave()

    let refreshedDraft = try XCTUnwrap(
      store.drafts.first(where: { $0.id == fixture.draft.id })
    )
    let contents = try String(contentsOf: fixture.destinationURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("重启后需要补写的新内容"))
    XCTAssertFalse(contents.contains("旧的项目文件内容"))
    XCTAssertEqual(
      refreshedDraft.repositoryBinding?.projectFileContentDigest,
      refreshedDraft.renderedRepositoryContentDigest(profile: store.activeProfile)
    )
    XCTAssertEqual(
      store.siteDraftFileSaveStates[fixture.draft.id]?.repositoryPath,
      fixture.draft.repositoryPath
    )
    XCTAssertTrue(draftPublications <= 1)
    XCTAssertNotEqual(try modificationDate(for: fixture.destinationURL), sentinelDate)
  }

  func testRemoteMaterializationRejectsDraftChangedAfterPackageReview() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-reviewed-package-drift")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")
      )
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }

    var draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Reviewed package",
      slug: "reviewed-package",
      bodyMarkdown: "The content that was shown on the confirmation page."
    )
    store.setDrafts([draft])
    let reviewedPackage = store.publishingPackage(for: draft)

    draft.bodyMarkdown = "Edited after the confirmation page was opened."
    store.updateDraft(draft)
    let didMaterialize = await store.publishingStore.ensureDraftMaterializedForRemotePublish(
      package: reviewedPackage,
      profile: store.activeProfile,
      store: store
    )

    XCTAssertFalse(didMaterialize)
    XCTAssertNil(store.drafts.first?.repositoryPath)
    XCTAssertTrue(try markdownProjectFiles(in: rootURL).isEmpty)
    XCTAssertEqual(
      store.publishActionMessage,
      CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。")
    )
  }

  func testAddingSiteDraftWithoutProjectKeepsAppDraftAndShowsFailure() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-without-project")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")
      )
    )

    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "等待加入项目"
    draft.slug = "waiting-for-project"
    draft.bodyMarkdown = "仍保存在软件中"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()

    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let didAddToProject = await store.writeSiteDraftToProject(draftID: draftID)
    XCTAssertFalse(didAddToProject)
    draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertNil(draft.repositoryPath)
    XCTAssertNil(draft.repositoryBinding)
    XCTAssertEqual(
      store.siteDraftFileSaveStates[draftID]?.repositoryPath,
      store.activeProfile.markdownPath(for: draft)
    )
    XCTAssertTrue(store.publishActionMessage?.contains("加入项目") == true)
    XCTAssertTrue(try markdownProjectFiles(in: rootURL).isEmpty)
  }

  func testGeneralDraftRemainsAppOnly() async throws {
    let rootURL = try temporaryDirectory(prefix: "general-draft-project")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")
      )
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
    }
    await store.waitForPendingSiteDraftFileWrites()
    let projectFilesBefore = try markdownProjectFiles(in: rootURL)

    store.createGeneralDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "只存软件"
    draft.slug = "app-only"
    draft.bodyMarkdown = "不应自动写进项目"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()

    XCTAssertTrue(try XCTUnwrap(store.selectedDraft).isGeneralDraft)
    XCTAssertNil(store.selectedDraft?.repositoryPath)
    XCTAssertNil(store.siteDraftFileSaveStates[draft.id])
    XCTAssertEqual(try markdownProjectFiles(in: rootURL), projectFilesBefore)
  }

  private func temporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: false
    )
    return url
  }

  private func makePersistedSiteDraft(
    rootURL: URL,
    bodyMarkdown: String
  ) throws -> PersistedSiteDraftFixture {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "启动 reconciliation 草稿",
      slug: "startup-reconciliation",
      bodyMarkdown: bodyMarkdown
    )
    let repositoryPath = profile.markdownPath(for: draft)
    let renderedDocument = FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try renderedDocument.write(to: destinationURL, atomically: true, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: repositoryPath,
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(renderedDocument)
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion,
      releaseRecords: []
    )
    return PersistedSiteDraftFixture(
      draft: draft,
      profile: profile,
      snapshot: snapshot,
      destinationURL: destinationURL
    )
  }

  private func modificationDate(for url: URL) throws -> Date {
    try XCTUnwrap(
      try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )
  }

  private func relativeProjectFiles(in rootURL: URL) throws -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    else {
      return []
    }
    return try enumerator.compactMap { element in
      guard let url = element as? URL,
        try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      else {
        return nil
      }
      return String(url.path.dropFirst(rootURL.path.count + 1))
    }.sorted()
  }

  private func markdownProjectFiles(in rootURL: URL) throws -> [String] {
    try relativeProjectFiles(in: rootURL).filter {
      $0.hasPrefix("content/") && $0.hasSuffix(".md")
    }
  }
}

extension SiteDraftFileSaveState {
  fileprivate var savedAtForTesting: Date? {
    guard case .saved(_, let savedAt) = self else { return nil }
    return savedAt
  }
}
