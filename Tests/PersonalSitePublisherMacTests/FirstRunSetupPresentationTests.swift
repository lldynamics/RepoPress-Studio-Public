import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class FirstRunSetupPresentationTests: XCTestCase {
  func testFirstRunOffersTheThreePathsInProductOrder() {
    XCTAssertEqual(
      FirstRunSetupPath.allCases.map(\.rawValue),
      [
        "connectExistingRepository",
        "createNewSite",
        "localDrafts",
      ]
    )
    XCTAssertEqual(
      FirstRunSetupPath.allCases.map(\.title),
      ["连接已有仓库", "创建新站点", "暂不配置站点"]
    )
    XCTAssertEqual(
      FirstRunSetupPath.allCases.map(\.destination),
      [.repositoryWizard, .siteStarter, .localDrafts]
    )
  }

  func testOnlyRepositoryPathCarriesAStagedProfileToTheFinalCommit() {
    var stagedProfile = SiteProfile.defaultProfile
    stagedProfile.applyPublishingDefaults(for: .astro)
    stagedProfile.localRepositoryRootPath = "/tmp/site"

    let repositoryCompletion = FirstRunSetupCompletion(
      path: .connectExistingRepository,
      stagedProfile: stagedProfile
    )
    XCTAssertEqual(repositoryCompletion.stagedProfile?.siteKind, .astro)
    XCTAssertEqual(repositoryCompletion.stagedProfile?.localRepositoryRootPath, "/tmp/site")

    let starterCompletion = FirstRunSetupCompletion(
      path: .createNewSite,
      stagedProfile: nil
    )
    let localDraftCompletion = FirstRunSetupCompletion(
      path: .localDrafts,
      stagedProfile: nil
    )
    XCTAssertNil(starterCompletion.stagedProfile)
    XCTAssertNil(localDraftCompletion.stagedProfile)
  }

  @MainActor
  func testStagedSiteKindAndPublishingChoicesDoNotMutateTheStoreBeforeFinalCommit() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstRunStaging-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    let originalProfile = store.activeProfile
    var staging = FirstRunSetupProfileStaging(profile: originalProfile)

    staging.selectSiteKind(.astro)
    staging.selectRepositoryProvider(.gitlab)
    staging.selectPublishStrategy(.reviewRequest)
    staging.selectRepositoryRoot(URL(fileURLWithPath: "/tmp/staged-site"))

    XCTAssertEqual(store.activeProfile, originalProfile)
    XCTAssertEqual(staging.profile.siteKind, .astro)
    XCTAssertEqual(staging.profile.repositoryProvider, .gitlab)
    XCTAssertEqual(staging.profile.repositoryPublishStrategy, .reviewRequest)
    XCTAssertEqual(staging.profile.localRepositoryRootPath, "/tmp/staged-site")
  }

  @MainActor
  func testRepositorySetupIsPersistedBeforeCompletionIsReported() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstRunCommit-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let initialStore = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    XCTAssertTrue(initialStore.saveCurrentStateSynchronously())
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    XCTAssertFalse(store.hasUnsavedChanges)
    var stagedProfile = store.activeProfile
    stagedProfile.localRepositoryRootPath = "/tmp/committed-site"

    let result = FirstRunSetupPersistenceCommit.apply(
      FirstRunSetupCompletion(
        path: .connectExistingRepository,
        stagedProfile: stagedProfile
      ),
      to: store
    )

    XCTAssertEqual(result, .completed)
    XCTAssertFalse(store.hasUnsavedChanges)
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    XCTAssertEqual(reloaded.activeProfile.localRepositoryRootPath, "/tmp/committed-site")
  }

  @MainActor
  func testRepositorySetupReportsFailureInsteadOfCompletingWhenPersistenceFails() {
    let invalidFileURL = URL(fileURLWithPath: "/dev/null/FirstRun-\(UUID().uuidString).json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: invalidFileURL))
    var repositoryDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "保留仓库绑定",
      slug: "keep-repository-binding",
      bodyMarkdown: "正文",
      repositoryPath: "content/post.md",
      repositorySHA: "known-remote-sha"
    )
    repositoryDraft.normalizeRepositoryBinding(for: store.activeProfile)
    store.setDrafts([repositoryDraft])
    let originalProfile = store.activeProfile
    let originalDraft = store.drafts[0]
    var stagedProfile = store.activeProfile
    stagedProfile.localRepositoryRootPath = "/tmp/not-persisted-site"
    stagedProfile.repositoryProvider = .gitlab
    stagedProfile.repositoryBaseURL = RepositoryProvider.gitlab.defaultBaseURL

    let result = FirstRunSetupPersistenceCommit.apply(
      FirstRunSetupCompletion(
        path: .connectExistingRepository,
        stagedProfile: stagedProfile
      ),
      to: store
    )

    guard case .failed(let message, let requiresSamePathRetry) = result else {
      return XCTFail("保存失败时不应报告首次设置完成")
    }
    XCTAssertTrue(message.contains("设置尚未标记为完成"))
    XCTAssertFalse(requiresSamePathRetry)
    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertEqual(store.activeProfile, originalProfile)
    XCTAssertEqual(store.drafts, [originalDraft])
    XCTAssertEqual(store.drafts[0].repositorySHA, "known-remote-sha")
  }

  @MainActor
  func testLocalDraftPersistenceFailureRequiresRetryingTheSamePath() {
    let invalidFileURL = URL(fileURLWithPath: "/dev/null/FirstRunLocal-\(UUID().uuidString).json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: invalidFileURL))

    let result = FirstRunSetupPersistenceCommit.apply(
      FirstRunSetupCompletion(path: .localDrafts, stagedProfile: nil),
      to: store
    )

    guard case .failed(_, let requiresSamePathRetry) = result else {
      return XCTFail("本地草稿保存失败时不应报告首次设置完成")
    }
    XCTAssertTrue(requiresSamePathRetry)
    XCTAssertEqual(store.activeProfile.purpose, .generalDraftBackup)
  }

  func testDraftRecoveryDiscardIsTheOnlyDestructiveRecoveryAction() {
    XCTAssertFalse(DraftRecoveryAction.restore.requiresConfirmation)
    XCTAssertFalse(DraftRecoveryAction.deferHandling.requiresConfirmation)
    XCTAssertTrue(DraftRecoveryAction.discard.requiresConfirmation)
  }

  @MainActor
  func testLocalDraftWorkspaceReusesAnEmptyDefaultProfile() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstRunLocalDrafts-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL)
    )

    store.prepareLocalDraftWorkspace()

    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.activeProfile.name, "本地草稿")
    XCTAssertEqual(store.activeProfile.purpose, SiteProfilePurpose.generalDraftBackup)
    XCTAssertTrue(store.activeProfile.localRepositoryRootPath.isEmpty)
    XCTAssertEqual(store.draftListContentScope, DraftListContentScope.general)
    XCTAssertEqual(store.selectedSection, WorkspaceSection.writing)
    XCTAssertTrue(store.selectedDraft?.isGeneralDraft == true)
  }
}
