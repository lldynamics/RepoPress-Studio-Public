import Combine
import Foundation

public enum FreshWorkspaceSeedPolicy: Sendable {
  case blank
  case softwareGuides
}

@MainActor
public final class WorkbenchStore: ObservableObject {
  private let imageWorkbenchService: SiteImageWorkbenchService
  let aiCredentialStore: AICredentialStore
  let siteAnalyticsService: SiteAnalyticsService
  let siteAnalyticsTokenStore: KeychainTokenStore
  private let aiPublishingAssistantService: AIPublishingAssistantService
  private let aiConnectionTestService: AIConnectionTestService
  private let aiDataSharingConsentStore: AIDataSharingConsentStore
  private let seoAuditService: SEOAuditService
  private let seoSocialPreviewService: SEOSocialPreviewService
  public let managedAttachmentFileStore: ManagedAttachmentFileStore
  public let rssReaderFileURL: URL?
  public let workspaceBackupDirectoryURL: URL?
  let siteDraftFileStore: SiteDraftFileStore
  let draftRecoveryJournal: DraftRecoveryJournal
  let draftRecoveryWriteCoordinator = DraftRecoveryJournalWriteCoordinator()
  var draftRecoveryRecords: [UUID: DraftRecoveryRecord]
  var draftRecoveryWriteTask: Task<Void, Never>?
  var draftRecoveryWriteGeneration: UInt64 = 0

  /// Safe mode keeps the persisted workspace available while skipping
  /// automatic preflight, preview, maintenance, and browser startup work.
  public let isSafeMode: Bool

  let publishingStore: PublishingStore
  let aiWorkspaceStore: AIWorkspaceStore
  let repositoryStore: RepositoryStore
  let deploymentStore: DeploymentStore
  let privacyProtectionStore: PrivacyProtectionStore
  let siteMaintenanceStore: SiteMaintenanceStore
  public let knowledge: KnowledgeStore
  let persistenceStore: WorkbenchPersistenceStore
  let repositoryDeploymentCoordinator: RepositoryDeploymentCoordinator

  public lazy var ai: WorkbenchAIFeatureFacade = WorkbenchAIFeatureFacade(store: self)
  public lazy var repository: WorkbenchRepositoryFeatureFacade = WorkbenchRepositoryFeatureFacade(
    store: self)
  public lazy var publishing: WorkbenchPublishingFeatureFacade = WorkbenchPublishingFeatureFacade(
    store: self)
  public lazy var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade =
    WorkbenchImageWorkbenchFeatureFacade(store: self)
  public lazy var persistenceStatus: WorkbenchPersistenceFeatureFacade =
    WorkbenchPersistenceFeatureFacade(store: self)
  public lazy var shell: WorkbenchShellFeatureFacade = WorkbenchShellFeatureFacade(store: self)
  public lazy var settings: WorkbenchSettingsFeatureFacade = WorkbenchSettingsFeatureFacade(
    store: self)
  public lazy var publishStatus: WorkbenchPublishStatusFeatureFacade =
    WorkbenchPublishStatusFeatureFacade(store: self)
  /// Stable, narrow observation boundary for the Writing sidebar.  The child
  /// owns list revisions so body autosaves do not invalidate the workbench
  /// root or the editor's presentation tree.
  public lazy var draftList: DraftListStore = DraftListStore(store: self)
  public lazy var siteMaintenance: WorkbenchSiteMaintenanceFeatureFacade =
    WorkbenchSiteMaintenanceFeatureFacade(store: self)
  public lazy var contentPresentation: WorkbenchContentPresentationFeatureFacade =
    WorkbenchContentPresentationFeatureFacade(store: self)
  public lazy var rootPresentation: WorkbenchRootPresentationFeatureFacade =
    WorkbenchRootPresentationFeatureFacade(store: self)
  public lazy var commandPresentation: WorkbenchCommandPresentationFeatureFacade =
    WorkbenchCommandPresentationFeatureFacade(store: self)
  public lazy var activityStatus: WorkbenchActivityStatusFacade = WorkbenchActivityStatusFacade(
    store: self)
  public lazy var workspaceLayout: WorkbenchWorkspaceLayoutFeatureFacade =
    WorkbenchWorkspaceLayoutFeatureFacade(store: self)
  public lazy var workspaceBackupScheduler: WorkspaceBackupScheduler =
    WorkspaceBackupScheduler(
      store: self,
      defaultDestinationFolderURL: workspaceBackupDirectoryURL
    )
  @Published public private(set) var contentHealthSnapshotVersion = 0
  @Published public private(set) var draftMutationRevision: UInt64 = 0
  @Published public private(set) var imageWorkbenchInputRevision: UInt64 = 0
  @Published public internal(set) var aiConnectionProfiles: [AIConnectionProfile]
  @Published public internal(set) var siteDraftFileSaveStates: [UUID: SiteDraftFileSaveState] = [:]
  @Published public internal(set) var pendingDraftRecoveries: [DraftRecoveryRecord] = []
  @Published public private(set) var draftRecoveryJournalErrorMessage: String?
  @Published public internal(set) var siteAnalyticsSummaries: [UUID: SiteAnalyticsSummary] = [:]
  @Published public internal(set) var isSiteAnalyticsLoading = false
  @Published public internal(set) var siteAnalyticsLoadingDraftID: UUID?
  @Published public internal(set) var siteAnalyticsMessage: String?
  @Published public internal(set) var siteAnalyticsTokenAvailability = KeychainTokenAvailability(
    hasToken: false)
  private var draftTaskQueueStateCache: [UUID: DraftTaskQueueState] = [:]
  /// Coalesces preflight refresh requests by draft. A metadata request keeps
  /// the pending list notification bit set even when a later body-only request
  /// cancels and replaces its delayed task; the eventual calculation therefore
  /// cannot downgrade a metadata invalidation to a body-only one.
  var pendingPreflightDraftListNotifications = Set<UUID>()
  private var knownArticleTitlesCacheRevision: UInt64?
  private var knownArticleTitlesCache = Set<String>()
  private var childStoreCancellables = Set<AnyCancellable>()
  var preflightRefreshTask: Task<Void, Never>?
  var preflightRefreshGeneration: UInt64 = 0
  var draftBodyCommitTasks: [UUID: Task<Void, Never>] = [:]
  var draftBodyCommitFirstStagedAt: [UUID: Date] = [:]
  var draftWordCountRefreshTasks: [UUID: Task<Void, Never>] = [:]
  var draftWordCountBackfillTask: Task<Void, Never>?
  var siteDraftFileAutosaveTasks: [UUID: Task<Void, Never>] = [:]
  var siteDraftFileReconciliationTask: Task<Void, Never>?
  var siteDraftFileReconciliationGeneration: UInt64 = 0
  var siteDraftFileWritesInProgress: Set<UUID> = []
  var siteDraftFileSaveGenerations: [UUID: UInt64] = [:]
  var siteMaintenanceRefreshTask: Task<SiteMaintenanceReport, Error>?
  var siteMaintenanceRefreshScheduleTask: Task<Void, Never>?
  var siteMaintenanceRefreshGeneration: UInt64 = 0
  var siteAnalyticsRefreshTask: Task<Void, Never>?
  var siteAnalyticsRefreshRequestID = UUID()
  var softwareGuideSeedVersion: Int

  lazy var aiStore: WorkbenchAIStore = WorkbenchAIStore(
    store: self,
    workspace: aiWorkspaceStore,
    aiPublishingAssistantService: aiPublishingAssistantService,
    aiCredentialStore: aiCredentialStore,
    aiConnectionTestService: aiConnectionTestService,
    aiDataSharingConsentStore: aiDataSharingConsentStore,
    imageWorkbenchService: imageWorkbenchService,
    seoAuditService: seoAuditService,
    seoSocialPreviewService: seoSocialPreviewService
  )
  lazy var imageStore: ImageWorkbenchStore = ImageWorkbenchStore(
    store: self,
    imageWorkbenchService: imageWorkbenchService,
    persistence: persistenceStore.persistence
  )

  public var profiles: [SiteProfile] { publishingStore.profiles }
  public var publishingProfiles: [SiteProfile] {
    publishingStore.profiles.filter { $0.purpose == .publishing }
  }
  public var activeProfileID: UUID { publishingStore.activeProfileID }
  public var drafts: [ArticleDraft] { publishingStore.drafts }
  /// Compatibility accessors for callers that still read the old root
  /// revision names.  Storage and observation now live in `draftList`.
  public var draftTaskQueueStateVersion: Int { draftList.taskQueueStateVersion }
  public var draftListPresentationRevision: UInt64 { draftList.presentationRevision }
  /// Titles used by markdown diagnostics. The set is rebuilt only after the
  /// draft collection mutates; body text staged in the editor does not touch it.
  public var knownArticleTitlesForMarkdownDiagnostics: Set<String> {
    if knownArticleTitlesCacheRevision == draftMutationRevision {
      return knownArticleTitlesCache
    }

    let titles = Set(
      drafts.compactMap { $0.title.trimmedForPublishing.nilIfEmpty }
    )
    knownArticleTitlesCache = titles
    knownArticleTitlesCacheRevision = draftMutationRevision
    return titles
  }
  public var draftVersions: [DraftVersionSnapshot] { publishingStore.draftVersions }
  public var markdownEditorSessionStates: [UUID: MarkdownEditorSessionState] {
    publishingStore.markdownEditorSessionStates
  }
  public var recycledDrafts: [RecycledDraft] { publishingStore.recycledDrafts }
  public var draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest] {
    publishingStore.draftRepositoryCleanupRequests
  }
  public var repositoryReport: RepositoryScanReport? {
    repositoryStore.repositoryReport(for: activeProfile, store: self)
  }
  public var imageWorkbenchReport: ImageWorkbenchReport? { publishingStore.imageWorkbenchReport }

  private static func normalizedLegacyCodexConfig(
    _ config: AIProviderConfig
  ) -> AIProviderConfig? {
    guard
      config.preset == .custom,
      config.baseURL == AIProviderPreset.codexAppServer.defaultBaseURL,
      !config.requiresAPIKey
    else {
      return nil
    }
    var normalized = config
    normalized.preset = .codexAppServer
    return normalized
  }

  public init(
    persistence: WorkbenchPersistence = WorkbenchPersistence(),
    initialSnapshotSource: WorkbenchInitialSnapshotSource = .persistence,
    safeMode: Bool = false,
    freshWorkspaceSeedPolicy: FreshWorkspaceSeedPolicy = .blank,
    preflightService: PreflightCheckService = PreflightCheckService(),
    repositoryService: LocalRepositoryService = LocalRepositoryService(),
    localContentImportService: LocalContentImportService = LocalContentImportService(),
    publishPackageBuilder: PublishPackageBuilder = PublishPackageBuilder(),
    localPublishPreviewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    remotePublishRiskService: RemotePublishRiskService = RemotePublishRiskService(),
    batchPublishPlanService: BatchPublishPlanService = BatchPublishPlanService(),
    batchPublishCommandBuilder: BatchPublishCommandBuilder = BatchPublishCommandBuilder(),
    repositorySyncCommandBuilder: RepositorySyncCommandBuilder = RepositorySyncCommandBuilder(),
    localSitePreviewService: LocalSitePreviewService = LocalSitePreviewService(),
    localSitePreviewProcessService: LocalSitePreviewProcessService =
      LocalSitePreviewProcessService(),
    remoteReviewDraftBuilder: RemoteReviewDraftBuilder = RemoteReviewDraftBuilder(),
    localGitPublishService: LocalGitPublishService = LocalGitPublishService(),
    remoteRepositoryPublishService: RemoteRepositoryPublishService =
      RemoteRepositoryPublishService(),
    deploymentStatusService: DeploymentStatusService = DeploymentStatusService(),
    siteAnalyticsService: SiteAnalyticsService = SiteAnalyticsService(),
    siteStarterService: SiteStarterService = SiteStarterService(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    seoAuditService: SEOAuditService = SEOAuditService(),
    seoSocialPreviewService: SEOSocialPreviewService = SEOSocialPreviewService(),
    siteMaintenanceService: SiteMaintenanceService = SiteMaintenanceService(),
    knowledgeLibraryService: KnowledgeLibraryService = KnowledgeLibraryService(),
    managedAttachmentFileStore: ManagedAttachmentFileStore = ManagedAttachmentFileStore(),
    rssReaderFileURL: URL? = nil,
    workspaceBackupDirectoryURL: URL? = nil,
    releaseLedgerService: ReleaseLedgerService = ReleaseLedgerService(),
    generalDraftLibraryService: GeneralDraftLibraryService = GeneralDraftLibraryService(),
    keychainTokenStore: KeychainTokenStore = KeychainTokenStore(),
    aiCredentialStore: AICredentialStore? = nil,
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.repository, accountPrefix: "repository-provider"),
    deploymentTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.deployment, accountPrefix: "deployment-provider"),
    siteAnalyticsTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.analytics, accountPrefix: "analytics-provider"),
    aiPublishingAssistantService: AIPublishingAssistantService = AIPublishingAssistantService(),
    aiConnectionTestService: AIConnectionTestService = AIConnectionTestService(),
    aiDataSharingConsentStore: AIDataSharingConsentStore = AIDataSharingConsentStore()
  ) {
    self.isSafeMode = safeMode
    let draftRecoveryJournal = DraftRecoveryJournal(
      fileURL: persistence.draftRecoveryJournalURL
    )
    let loadedDraftRecoveryRecords: [DraftRecoveryRecord]
    let draftRecoveryLoadErrorMessage: String?
    do {
      loadedDraftRecoveryRecords = try draftRecoveryJournal.load()
      draftRecoveryLoadErrorMessage = nil
    } catch {
      loadedDraftRecoveryRecords = []
      if let quarantineURL = try? draftRecoveryJournal.quarantineUnreadableFile() {
        draftRecoveryLoadErrorMessage = CoreL10n.format(
          "未保存草稿恢复日志无法读取，原文件已隔离：%@（%@）",
          error.localizedDescription,
          quarantineURL.path
        )
      } else {
        draftRecoveryLoadErrorMessage = CoreL10n.format(
          "未保存草稿恢复日志无法读取，原文件保持不变：%@",
          error.localizedDescription
        )
      }
    }
    self.persistenceStore = WorkbenchPersistenceStore(persistence: persistence)
    self.imageWorkbenchService = imageWorkbenchService
    self.aiCredentialStore =
      aiCredentialStore
      ?? AICredentialStore(keychainTokenStore: keychainTokenStore)
    self.siteAnalyticsService = siteAnalyticsService
    self.siteAnalyticsTokenStore = siteAnalyticsTokenStore
    self.aiPublishingAssistantService = aiPublishingAssistantService
    self.aiConnectionTestService = aiConnectionTestService
    self.aiDataSharingConsentStore = aiDataSharingConsentStore
    self.seoAuditService = seoAuditService
    self.seoSocialPreviewService = seoSocialPreviewService
    self.managedAttachmentFileStore = managedAttachmentFileStore
    self.rssReaderFileURL = rssReaderFileURL
    self.workspaceBackupDirectoryURL = workspaceBackupDirectoryURL
    self.siteDraftFileStore = SiteDraftFileStore(
      packageBuilder: publishPackageBuilder,
      previewService: localPublishPreviewService
    )
    self.draftRecoveryJournal = draftRecoveryJournal
    self.draftRecoveryRecords = Self.mergedRecoveryRecords(from: loadedDraftRecoveryRecords)
    self.siteMaintenanceStore = SiteMaintenanceStore()
    self.knowledge = KnowledgeStore(service: knowledgeLibraryService)

    let snapshotLoad: WorkbenchSnapshotLoadResult
    let requiresPersistenceRecoveryDecision: Bool
    switch initialSnapshotSource {
    case .persistence:
      do {
        snapshotLoad = try persistenceStore.loadWithRecovery()
        requiresPersistenceRecoveryDecision = false
      } catch {
        snapshotLoad = WorkbenchSnapshotLoadResult(
          snapshot: nil,
          recoveryMessage: "工作台数据无法读取，已使用空白工作台启动。原始文件未被覆盖：\(error.localizedDescription)"
        )
        requiresPersistenceRecoveryDecision = true
      }
    case .preloaded(let result):
      snapshotLoad = result
      requiresPersistenceRecoveryDecision = false
    case .loadFailure(let message):
      snapshotLoad = WorkbenchSnapshotLoadResult(
        snapshot: nil,
        recoveryMessage: "工作台数据无法读取，已使用空白工作台启动。原始文件未被覆盖：\(message)"
      )
      requiresPersistenceRecoveryDecision = true
    }
    let snapshot = snapshotLoad.snapshot
    let snapshotProfiles = snapshot?.profiles ?? []
    let restoredProfiles =
      snapshotProfiles.isEmpty ? [SiteProfile.defaultProfile] : snapshotProfiles
    var initialProfiles =
      restoredProfiles.contains(where: { $0.purpose == .publishing })
      ? restoredProfiles
      : restoredProfiles + [SiteProfile.defaultProfile]
    var initialAIConnectionProfiles = snapshot?.aiConnectionProfiles ?? []
    var didMigrateAIConnectionProfiles = false
    var normalizedConnectionProfileIDs = Set<UUID>()
    for index in initialAIConnectionProfiles.indices {
      guard
        let normalizedConfig = Self.normalizedLegacyCodexConfig(
          initialAIConnectionProfiles[index].config
        )
      else {
        continue
      }
      initialAIConnectionProfiles[index].config = normalizedConfig
      normalizedConnectionProfileIDs.insert(initialAIConnectionProfiles[index].id)
      didMigrateAIConnectionProfiles = true
    }
    var normalizedInlineProfileIDs = Set<UUID>()
    for index in initialProfiles.indices {
      guard
        let normalizedConfig = Self.normalizedLegacyCodexConfig(
          initialProfiles[index].aiProviderConfig
        )
      else {
        continue
      }
      initialProfiles[index].aiProviderConfig = normalizedConfig
      normalizedInlineProfileIDs.insert(initialProfiles[index].id)
      didMigrateAIConnectionProfiles = true
    }
    // A selected reusable connection is the source of truth. Keep its legacy
    // inline compatibility field in lockstep when either side was repaired so
    // older exports cannot reintroduce the malformed Codex shape.
    for index in initialProfiles.indices {
      guard
        let selectedID = initialProfiles[index].aiConnectionProfileID,
        let connection = initialAIConnectionProfiles.first(where: { $0.id == selectedID }),
        normalizedConnectionProfileIDs.contains(selectedID)
          || normalizedInlineProfileIDs.contains(initialProfiles[index].id)
      else {
        continue
      }
      if initialProfiles[index].aiProviderConfig != connection.config {
        initialProfiles[index].aiProviderConfig = connection.config
        didMigrateAIConnectionProfiles = true
      }
    }
    for index in initialProfiles.indices {
      let siteProfile = initialProfiles[index]
      if let selectedID = siteProfile.aiConnectionProfileID,
        initialAIConnectionProfiles.contains(where: { $0.id == selectedID })
      {
        continue
      }

      if let matchingProfile = initialAIConnectionProfiles.first(where: {
        $0.config == siteProfile.aiProviderConfig
      }) {
        initialProfiles[index].aiConnectionProfileID = matchingProfile.id
        didMigrateAIConnectionProfiles = true
      } else {
        let connectionProfile = AIConnectionProfile(
          name: siteProfile.aiProviderConfig.normalizedDisplayName,
          config: siteProfile.aiProviderConfig
        )
        initialAIConnectionProfiles.append(connectionProfile)
        initialProfiles[index].aiConnectionProfileID = connectionProfile.id
        didMigrateAIConnectionProfiles = true
      }
    }
    self.aiConnectionProfiles = Array(initialAIConnectionProfiles.prefix(64))
    let initialPublishingProfiles = initialProfiles.filter { $0.purpose == .publishing }
    let restoredActiveProfileID = (snapshot?.activeProfileID).flatMap { candidate in
      initialPublishingProfiles.contains(where: { $0.id == candidate }) ? candidate : nil
    }
    let initialActiveProfileID = restoredActiveProfileID ?? initialPublishingProfiles[0].id
    let activeProfile =
      initialProfiles.first { $0.id == initialActiveProfileID } ?? initialProfiles[0]
    let snapshotDrafts = snapshot?.drafts ?? []
    let shouldInstallDefaultSoftwareGuides: Bool
    switch freshWorkspaceSeedPolicy {
    case .blank:
      shouldInstallDefaultSoftwareGuides = false
    case .softwareGuides:
      shouldInstallDefaultSoftwareGuides =
        snapshotLoad.recoveryMessage == nil
        && (snapshot?.softwareGuideSeedVersion ?? 0)
          < ArticleDraft.currentSoftwareGuideSeedVersion
    }
    var initialDrafts: [ArticleDraft]
    if !snapshotDrafts.isEmpty {
      initialDrafts = snapshotDrafts.map { draft in
        var normalized = draft
        normalized.normalizeLegacyScope()
        return normalized
      }
    } else if shouldInstallDefaultSoftwareGuides {
      initialDrafts = []
    } else {
      initialDrafts = [ArticleDraft.empty(profile: activeProfile)]
    }
    let draftsBeforeSoftwareGuideSeed = initialDrafts
    var initialSoftwareGuideSeedVersion = snapshot?.softwareGuideSeedVersion ?? 0
    var didInstallDefaultSoftwareGuides = false
    if shouldInstallDefaultSoftwareGuides {
      let synchronization = ArticleDraft.synchronizeSoftwareGuides(
        in: initialDrafts,
        profile: activeProfile,
        previousSeedVersion: initialSoftwareGuideSeedVersion
      )
      initialDrafts = synchronization.drafts
      initialSoftwareGuideSeedVersion = ArticleDraft.currentSoftwareGuideSeedVersion
      didInstallDefaultSoftwareGuides = true
    }
    // A missing persisted word count is a migration marker, but recalculating
    // every loaded draft during startup changes the snapshot while site-file
    // reconciliation and other startup services are still taking their
    // baselines. Backfill the drafts created by this startup (and managed
    // guides whose body was refreshed), while leaving unchanged loaded drafts
    // for the normal body-edit path.
    let startupWordCountBackfillDrafts = initialDrafts.filter { draft in
      guard draft.wordCountNeedsRefresh else { return false }
      if snapshotDrafts.isEmpty {
        return true
      }
      guard let previousDraft = draftsBeforeSoftwareGuideSeed.first(where: {
        $0.id == draft.id
      }) else {
        return true
      }
      return previousDraft.bodyMarkdown != draft.bodyMarkdown
    }
    let unresolvedDraftRecoveryRecords = loadedDraftRecoveryRecords.filter { record in
      guard let draft = initialDrafts.first(where: { $0.id == record.draftID }) else {
        return true
      }
      return draft.bodyMarkdown != record.recoveredBodyMarkdown
    }
    self.draftRecoveryRecords = Self.mergedRecoveryRecords(from: unresolvedDraftRecoveryRecords)
    self.pendingDraftRecoveries = unresolvedDraftRecoveryRecords.sorted {
      $0.capturedAt > $1.capturedAt
    }
    self.draftRecoveryJournalErrorMessage = draftRecoveryLoadErrorMessage
    self.softwareGuideSeedVersion = initialSoftwareGuideSeedVersion
    let initialDraftListContentScope: DraftListContentScope =
      initialDrafts.contains { $0.belongs(toSiteProfileID: initialActiveProfileID) }
      ? .currentSite
      : .general
    let initialSelectedDraftID = initialDrafts.first { draft in
      switch initialDraftListContentScope {
      case .currentSite:
        return draft.belongs(toSiteProfileID: initialActiveProfileID)
      case .general:
        return draft.isGeneralDraft
      }
    }?.id

    self.privacyProtectionStore = PrivacyProtectionStore(
      privacySettings: snapshot?.privacySettings ?? .default
    )
    self.repositoryStore = RepositoryStore(
      remoteRepositoryAccessCheck: snapshot?.remoteRepositoryAccessCheck,
      remoteRepositoryAccessCheckByProfileID:
        snapshot?.remoteRepositoryAccessCheckByProfileID ?? [:],
      repositoryAutoSyncSettings: snapshot?.repositoryAutoSyncSettings ?? .default,
      repositoryAutoSyncState: snapshot?.repositoryAutoSyncState ?? .idle,
      repositoryAutoSyncSettingsByProfileID:
        snapshot?.repositoryAutoSyncSettingsByProfileID ?? [:],
      repositoryAutoSyncStateByProfileID:
        snapshot?.repositoryAutoSyncStateByProfileID ?? [:],
      activeProfileID: initialActiveProfileID,
      repositoryService: repositoryService,
      repositoryTokenStore: repositoryTokenStore,
      remoteRepositoryPublishService: remoteRepositoryPublishService,
      repositorySyncCommandBuilder: repositorySyncCommandBuilder
    )
    self.deploymentStore = DeploymentStore(
      deploymentStatusSnapshots: Dictionary(
        (snapshot?.deploymentStatusSnapshots ?? []).compactMap { snapshot in
          snapshot.releaseRecordID.map { ($0, snapshot) }
        },
        uniquingKeysWith: { current, candidate in
          candidate.checkedAt > current.checkedAt ? candidate : current
        }
      ),
      deploymentStatusHistory: snapshot?.deploymentStatusHistory ?? [:],
      deploymentPollingSettings: snapshot?.deploymentPollingSettings ?? .default,
      deploymentPollingState: snapshot?.deploymentPollingState ?? .idle,
      deploymentPollingSettingsByProfileID:
        snapshot?.deploymentPollingSettingsByProfileID ?? [:],
      deploymentPollingStateByProfileID:
        snapshot?.deploymentPollingStateByProfileID ?? [:],
      activeProfileID: initialActiveProfileID,
      deploymentStatusService: deploymentStatusService,
      deploymentTokenStore: deploymentTokenStore,
      releaseLedgerService: releaseLedgerService
    )
    self.repositoryDeploymentCoordinator = RepositoryDeploymentCoordinator(
      repositoryStore: repositoryStore,
      deploymentStore: deploymentStore
    )
    self.aiWorkspaceStore = AIWorkspaceStore(
      aiMetadataApplicationRecords: snapshot?.aiMetadataApplicationRecords ?? [],
      automationRunRecords: snapshot?.automationRunRecords ?? [],
      aiChatCustomPrompts: snapshot?.aiChatCustomPrompts ?? [],
      aiConversations: snapshot?.aiConversations ?? [],
      activeAIConversationIDsByDraftID: snapshot?.activeAIConversationIDsByDraftID ?? [:],
      activeAIConversationIDsByScope: snapshot?.activeAIConversationIDsByScope ?? [:],
      seoSocialPreviewSnapshots: Dictionary(
        (snapshot?.seoSocialPreviewSnapshots ?? []).map { ($0.draftID, $0) },
        uniquingKeysWith: { current, candidate in
          candidate.generatedAt > current.generatedAt ? candidate : current
        }
      )
    )
    self.publishingStore = PublishingStore(
      profiles: initialProfiles,
      activeProfileID: initialActiveProfileID,
      drafts: initialDrafts,
      customMarkdownSnippets: snapshot?.customMarkdownSnippets ?? [],
      draftVersions: snapshot?.draftVersions ?? [],
      recycledDrafts: snapshot?.recycledDrafts ?? [],
      draftRepositoryCleanupRequests: snapshot?.draftRepositoryCleanupRequests ?? [],
      releaseRecords: snapshot?.releaseRecords ?? [],
      selectedDraftID: initialSelectedDraftID,
      draftListContentScope: initialDraftListContentScope,
      markdownEditorSessionStates: snapshot?.markdownEditorSessionStates ?? [:],
      maintenanceOperationRecords: snapshot?.maintenanceOperationRecords ?? [],
      preflightService: preflightService,
      publishPackageBuilder: publishPackageBuilder,
      localPublishPreviewService: localPublishPreviewService,
      batchPublishPlanService: batchPublishPlanService,
      remoteRepositoryPublishService: remoteRepositoryPublishService,
      repositoryTokenStore: repositoryTokenStore,
      localGitPublishService: localGitPublishService,
      remoteReviewDraftBuilder: remoteReviewDraftBuilder,
      batchPublishCommandBuilder: batchPublishCommandBuilder,
      remotePublishRiskService: remotePublishRiskService,
      localContentImportService: localContentImportService,
      siteStarterService: siteStarterService,
      generalDraftLibraryService: generalDraftLibraryService,
      localSitePreviewService: localSitePreviewService,
      localSitePreviewProcessService: localSitePreviewProcessService,
      siteMaintenanceService: siteMaintenanceService,
      imageWorkbenchService: imageWorkbenchService
    )
    // Install the stable child observation boundary before any startup
    // services can mutate drafts or repository/privacy projections.
    _ = draftList
    repositoryStore.setActiveProfile(
      initialActiveProfileID,
      validProfileIDs: Set(initialProfiles.map(\.id))
    )
    deploymentStore.setActiveProfile(
      initialActiveProfileID,
      validProfileIDs: Set(initialProfiles.map(\.id))
    )
    publishingStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    publishingStore.$drafts
      .dropFirst()
      .sink { [weak self] _ in
        guard let self else { return }
        self.draftMutationRevision &+= 1
        self.knownArticleTitlesCacheRevision = nil
      }
      .store(in: &childStoreCancellables)
    publishingStore.$drafts
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] drafts in
        guard let self else { return }
        let validDraftIDs = Set(drafts.map(\.id))
        self.aiStore.reconcileAIDraftSuggestionState(validDraftIDs: validDraftIDs)
        self.imageStore.reconcileDraftReportState(validDraftIDs: validDraftIDs)
        // A surviving draft may have changed enough to invalidate a cached
        // suggestion or image report even when its identifier remains valid.
        self.aiStore.restoreDraftSuggestionProjectionForCurrentSelection()
        self.imageStore.restoreImageWorkbenchReportProjectionForCurrentSelection()
      }
      .store(in: &childStoreCancellables)
    publishingStore.$selectedDraftID
      .removeDuplicates()
      .dropFirst()
      // @Published emits from willSet. Deliver on the next main-run-loop turn
      // so every direct selection mutation has committed before projections
      // query `selectedDraftID`.
      .receive(on: RunLoop.main)
      .sink { [weak self] selectedDraftID in
        guard let self, self.selectedDraftID == selectedDraftID else { return }
        self.restoreSEOSocialPreviewSnapshotForCurrentSelection()
      }
      .store(in: &childStoreCancellables)
    publishingStore.$activeProfileID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] profileID in
        guard let self,
          let profile = self.publishingStore.profiles.first(where: { $0.id == profileID })
        else {
          return
        }
        self.repositoryStore.setActiveProfile(
          profileID,
          validProfileIDs: Set(self.publishingStore.profiles.map(\.id))
        )
        self.deploymentStore.setActiveProfile(
          profileID,
          validProfileIDs: Set(self.publishingStore.profiles.map(\.id))
        )
        self.aiStore.refreshAIKeyAvailability(for: profile)
        self.refreshSiteAnalyticsTokenAvailability(for: profile)
      }
      .store(in: &childStoreCancellables)
    repositoryStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    privacyProtectionStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    persistenceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    persistenceStore.$status
      .sink { [weak self] status in self?.publishingStore.lastSaveStatus = status }
      .store(in: &childStoreCancellables)
    siteMaintenanceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    knowledge.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    repositoryDeploymentCoordinator.refreshTokenAvailability(store: self)
    aiStore.refreshAIKeyAvailability()
    refreshSiteAnalyticsTokenAvailability()
    if let recoveryMessage = snapshotLoad.recoveryMessage {
      if requiresPersistenceRecoveryDecision {
        persistenceStore.protectWritesForUnrecoverableSnapshot(message: recoveryMessage)
      } else {
        persistenceStore.setRecoveryMessage(recoveryMessage)
        setLastSaveStatus(CoreL10n.text("需要检查工作台数据"))
      }
    }
    if didInstallDefaultSoftwareGuides {
      save()
    } else if didMigrateAIConnectionProfiles {
      // Central AI connection IDs are normalized in memory during startup.
      // Mark the snapshot dirty so the normal exit/autosave path persists the
      // migration without writing through a preloaded snapshot immediately.
      persistenceStore.markUnsavedChanges()
    }
    if isSafeMode {
      setLastSaveStatus(CoreL10n.text("安全模式：已暂停自动工作区服务"))
    } else {
      scheduleDirtyDraftWordCountRefreshes(for: startupWordCountBackfillDrafts)
      runPreflight()
      refreshPublishPreviewInBackground(for: selectedDraft)
      aiStore.restoreSEOSocialPreviewSnapshotForCurrentSelection()
      scheduleSiteMaintenanceSnapshotRefresh()
      scheduleMissingSiteDraftFileWrites()
    }
  }

  public var activeProfile: SiteProfile { publishingStore.activeProfile }

  public var selectedDraft: ArticleDraft? { publishingStore.selectedDraft }

  public var visibleDrafts: [ArticleDraft] { publishingStore.visibleDrafts }

  public var writingDrafts: [ArticleDraft] { publishingStore.writingDrafts }

  public func profile(for draft: ArticleDraft) -> SiteProfile {
    publishingStore.profile(for: draft)
  }

  public func profile(for record: ReleaseRecord) -> SiteProfile {
    publishingStore.profile(for: record)
  }

  func profile(for package: PublishPackage) -> SiteProfile { publishingStore.profile(for: package) }

  public func save() {
    flushDraftBodyEditorBuffers()
    let input = persistenceStore.persistence.snapshotInput(from: self)
    persistenceStore.saveImmediately(input: input)
  }

  func waitForPendingSave() async {
    while true {
      await persistenceStore.waitForPendingSave()
      await waitForPendingDraftWordCountRefreshes()
      await Task.yield()
      await persistenceStore.waitForPendingSave()
      if draftWordCountRefreshTasks.isEmpty && draftWordCountBackfillTask == nil {
        return
      }
    }
  }

  /// Saves immediately and reports whether it is safe to let the process exit.
  @discardableResult
  public func flushPendingChanges() -> Bool {
    flushDraftBodyEditorBuffers()
    let siteDraftFilesSucceeded = flushPendingSiteDraftFileWrites()
    let input = persistenceStore.persistence.snapshotInput(from: self)
    let persistenceSucceeded = persistenceStore.flush(
      input: input
    )
    let primarySaveSucceeded =
      siteDraftFilesSucceeded
      && persistenceSucceeded
      && !persistenceStore.isRecoveryWriteProtected
    let draftRecoverySucceeded = flushDraftRecoveryJournal(
      pruningResolvedRecords: primarySaveSucceeded
    )
    return siteDraftFilesSucceeded && persistenceSucceeded && draftRecoverySucceeded
  }

  func scheduleAutosave() {
    persistenceStore.scheduleAutosave(input: { [weak self] in
      guard let self else { return nil }
      return self.persistenceStore.persistence.snapshotInput(from: self)
    })
  }

  func scheduleDraftRecoveryJournalWrite() {
    draftRecoveryWriteTask?.cancel()
    draftRecoveryWriteGeneration &+= 1
    let generation = draftRecoveryWriteGeneration
    let journal = draftRecoveryJournal
    let coordinator = draftRecoveryWriteCoordinator
    draftRecoveryWriteTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
        try Task.checkCancellation()
        guard self?.draftRecoveryWriteGeneration == generation else { return }
        guard let records = self?.draftRecoveryRecords.values.sorted(
          by: { $0.capturedAt > $1.capturedAt }
        ) else { return }
        try Task.checkCancellation()
        _ = try await Task.detached(priority: .utility) {
          try coordinator.save(records, to: journal, generation: generation)
        }.value
        try Task.checkCancellation()
        self?.finishDraftRecoveryJournalWrite(
          generation: generation,
          failureDescription: nil
        )
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.finishDraftRecoveryJournalWrite(
          generation: generation,
          failureDescription: error.localizedDescription
        )
      }
    }
  }

  func waitForPendingDraftRecoveryJournalWrite() async {
    let task = draftRecoveryWriteTask
    await task?.value
  }

  @discardableResult
  func flushDraftRecoveryJournal(pruningResolvedRecords: Bool = true) -> Bool {
    draftRecoveryWriteTask?.cancel()
    draftRecoveryWriteTask = nil
    draftRecoveryWriteGeneration &+= 1
    let generation = draftRecoveryWriteGeneration
    if pruningResolvedRecords {
      let resolvedDraftIDs = draftRecoveryRecords.compactMap { draftID, record -> UUID? in
        guard let draft = drafts.first(where: { $0.id == draftID }),
          draft.bodyMarkdown == record.recoveredBodyMarkdown
        else {
          return nil
        }
        return draftID
      }
      for draftID in resolvedDraftIDs {
        draftRecoveryRecords.removeValue(forKey: draftID)
      }
    }
    refreshPendingDraftRecoveries()
    do {
      try draftRecoveryWriteCoordinator.save(
        Array(draftRecoveryRecords.values),
        to: draftRecoveryJournal,
        generation: generation
      )
      finishDraftRecoveryJournalWrite(
        generation: generation,
        failureDescription: nil
      )
      return true
    } catch {
      finishDraftRecoveryJournalWrite(
        generation: generation,
        failureDescription: error.localizedDescription
      )
      return false
    }
  }

  private func finishDraftRecoveryJournalWrite(
    generation: UInt64,
    failureDescription: String?
  ) {
    guard draftRecoveryWriteGeneration == generation else { return }
    draftRecoveryWriteTask = nil
    draftRecoveryJournalErrorMessage = failureDescription.map {
      CoreL10n.format("未保存草稿恢复日志写入失败：%@", $0)
    }
  }

  func invalidateDraftDerivedCaches(notifyingDraftList: Bool = true) {
    publishingStore.removeAllDraftPublishPreviewSnapshots()
    invalidateContentHealthSnapshot()
    invalidateSiteMaintenanceSnapshot()
    draftTaskQueueStateCache.removeAll()
    if notifyingDraftList {
      draftList.invalidatePresentationAndTaskQueueState()
    }
    imageWorkbenchInputRevision &+= 1
  }

  func invalidateBodyEditingDerivedCaches(
    for draftID: UUID,
    imageInputsDidChange: Bool
  ) {
    // Body typing does not alter images, release history, or maintenance
    // metadata. Keep those expensive summaries warm until a debounced
    // preflight refresh runs.
    publishingStore.removeDraftPublishPreviewSnapshot(
      for: draftID,
      preservingSelectedProjection: true
    )
    invalidateContentHealthSnapshot()
    draftTaskQueueStateCache.removeValue(forKey: draftID)
    if imageInputsDidChange {
      imageWorkbenchInputRevision &+= 1
    }
  }

  private func invalidateContentHealthSnapshot() {
    contentHealthSnapshotVersion += 1
  }

  func invalidateDraftTaskQueueStateCache() {
    draftTaskQueueStateCache.removeAll()
    draftList.invalidateTaskQueueState()
  }

  func imageWorkbenchBackgroundStateDidChange() {
    objectWillChange.send()
  }

  func invalidateSiteMaintenanceSnapshot() {
    siteMaintenanceRefreshGeneration &+= 1
    siteMaintenanceRefreshTask?.cancel()
    siteMaintenanceRefreshTask = nil
    siteMaintenanceStore.invalidate()
    scheduleSiteMaintenanceSnapshotRefresh()
  }

  public func draftTaskQueueStates(for drafts: [ArticleDraft]) -> [UUID: DraftTaskQueueState] {
    let imageIssueCounts = Dictionary(
      uniqueKeysWithValues: (cachedImageWorkbenchSiteSummary?.draftSummaries ?? []).map { summary in
        (summary.draftID, summary.issueCount)
      }
    )
    let repositoryReadinessFingerprint = [
      repositoryReport?.rootPath ?? "",
      repositoryReport?.statusTitle ?? "",
      repositoryReport?.syncStatusTitle ?? "",
      "\(repositoryReport?.changedFiles.count ?? 0)",
      "\(repositoryReport?.remoteChangedFiles.count ?? 0)",
    ].joined(separator: "|")
    // Callers may deliberately retain list-rendered snapshots while body
    // autosave keeps the list boundary silent. Treat the argument as an
    // identity selection and always evaluate current store values so a later
    // user-triggered "check failed" filter cannot inspect stale Markdown.
    let draftIDs = Set(drafts.map(\.id))
    let currentDrafts = self.drafts.filter { draftIDs.contains($0.id) }
    let preflightDrafts = self.drafts.filter { $0.belongs(toSiteProfileID: activeProfileID) }
    let preflightDuplicateIndex = PreflightDuplicateIndex(
      drafts: preflightDrafts,
      profile: activeProfile
    )
    draftTaskQueueStateCache = draftTaskQueueStateCache.filter { draftIDs.contains($0.key) }

    return Dictionary(
      uniqueKeysWithValues: currentDrafts.map { draft in
        let imageIssueCount = imageIssueCounts[draft.id] ?? 0
        let signature = DraftTaskQueueState.Signature(
          draft: draft,
          profileID: activeProfileID,
          imageIssueCount: imageIssueCount,
          repositoryReadinessFingerprint: repositoryReadinessFingerprint
        )
        if let cached = draftTaskQueueStateCache[draft.id], cached.signature == signature {
          return (draft.id, cached)
        }

        let state = DraftTaskQueueState(
          draftID: draft.id,
          signature: signature,
          hasPreflightErrors: publishingStore.preflightIssues(
            for: draft,
            includeRepositoryReadiness: true,
            allDrafts: preflightDrafts,
            duplicateIndex: preflightDuplicateIndex,
            store: self
          ).contains { $0.severity == .error },
          hasImageIssues: imageIssueCount > 0
        )
        draftTaskQueueStateCache[draft.id] = state
        return (draft.id, state)
      }
    )
  }

  func isSiteMaintenanceSnapshotStaleState() -> Bool {
    siteMaintenanceStore.isStale()
  }

  func replaceSiteMaintenanceSnapshot(
    report: SiteMaintenanceReport,
    inputSignature: SiteMaintenanceReportInputSignature
  ) {
    siteMaintenanceStore.replaceSnapshot(
      report: report,
      profileID: activeProfileID,
      profileName: activeProfile.name,
      draftCount: visibleDrafts.count,
      inputSignature: inputSignature
    )
  }

  public func draft(for draftID: UUID) -> ArticleDraft? {
    publishingStore.draft(for: draftID)
  }

  static func mergedRecoveryRecords(from records: [DraftRecoveryRecord]) -> [UUID:
    DraftRecoveryRecord]
  {
    Dictionary(
      records.map { ($0.draftID, $0) },
      uniquingKeysWith: { lhs, rhs in
        lhs.capturedAt >= rhs.capturedAt ? lhs : rhs
      }
    )
  }
}
