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
  func testAutoConfigurationProposalOnlyChangesTheStagedProfile() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstRunAutoConfiguration-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    let originalProfile = store.activeProfile
    let repositoryURL = URL(fileURLWithPath: "/tmp/detected-astro-site", isDirectory: true)
    let proposal = RepositoryAutoConfigurationProposal(
      detectedKind: .astro,
      evidence: ["astro.config.mjs"],
      isGitRepository: true,
      contentRoot: "src/content/articles",
      assetRoot: "public",
      frontMatterStyle: .yaml,
      markdownPathPattern: "src/content/articles/{slug}.mdx"
    )
    var staging = FirstRunSetupProfileStaging(profile: originalProfile)

    staging.applyAutoConfigurationProposal(proposal, repositoryURL: repositoryURL)

    XCTAssertEqual(store.activeProfile, originalProfile)
    XCTAssertEqual(staging.profile.siteKind, .astro)
    XCTAssertEqual(staging.profile.localRepositoryRootPath, repositoryURL.path)
    XCTAssertEqual(staging.profile.contentRoot, "src/content/articles")
    XCTAssertEqual(staging.profile.assetRoot, "public")
    XCTAssertEqual(staging.profile.frontMatterStyle, .yaml)
    XCTAssertEqual(staging.profile.markdownPathPattern, "src/content/articles/{slug}.mdx")
  }

  func testManualRuleOverridesRemainInTheStagedProfile() {
    var staging = FirstRunSetupProfileStaging(profile: .defaultProfile)

    staging.selectSiteKind(.hugo)
    staging.selectFrontMatterStyle(.toml)
    staging.setContentRoot("content/articles")
    staging.setMarkdownPathPattern("content/articles/{year}/{slug}.md")

    XCTAssertEqual(staging.profile.siteKind, .hugo)
    XCTAssertEqual(staging.profile.frontMatterStyle, .toml)
    XCTAssertEqual(staging.profile.contentRoot, "content/articles")
    XCTAssertEqual(staging.profile.markdownPathPattern, "content/articles/{year}/{slug}.md")
  }

  @MainActor
  func testSelectingExistingAIConnectionOnlyStagesItsIDAndConfiguration() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FirstRunAIConnection-\(UUID().uuidString)", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    let originalProfile = store.activeProfile
    let connection = AIConnectionProfile.template(
      named: "现有连接",
      preset: .local
    )
    var staging = FirstRunSetupProfileStaging(profile: originalProfile)

    staging.selectAIConnection(connection)

    XCTAssertEqual(store.activeProfile, originalProfile)
    XCTAssertEqual(staging.profile.aiConnectionProfileID, connection.id)
    XCTAssertEqual(staging.profile.aiProviderConfig, connection.config)

    XCTAssertEqual(store.activeProfile, originalProfile)
  }

  func testSkippingAPreviouslySelectedAIConnectionRestoresPersistedSelection() {
    let persistedConnection = AIConnectionProfile.template(
      named: "已有连接",
      preset: .openAICompatible
    )
    let temporaryConnection = AIConnectionProfile.template(
      named: "临时连接",
      preset: .local
    )
    var persistedProfile = SiteProfile.defaultProfile
    persistedProfile.aiConnectionProfileID = persistedConnection.id
    persistedProfile.aiProviderConfig = persistedConnection.config
    var staging = FirstRunSetupProfileStaging(profile: persistedProfile)

    staging.selectAIConnection(temporaryConnection)
    staging.restoreAIConnection(from: persistedProfile)

    XCTAssertEqual(staging.profile.aiConnectionProfileID, persistedConnection.id)
    XCTAssertEqual(staging.profile.aiProviderConfig, persistedConnection.config)
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
