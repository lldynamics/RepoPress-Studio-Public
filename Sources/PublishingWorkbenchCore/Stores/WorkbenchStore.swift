import Combine
import Foundation

@MainActor
public final class WorkbenchStore: ObservableObject {
  private let imageWorkbenchService: SiteImageWorkbenchService
  private let keychainTokenStore: KeychainTokenStore
  private let aiPublishingAssistantService: AIPublishingAssistantService
  private let aiConnectionTestService: AIConnectionTestService
  private let seoAuditService: SEOAuditService
  private let seoSocialPreviewService: SEOSocialPreviewService

  let publishingStore: PublishingStore
  let aiWorkspaceStore: AIWorkspaceStore
  let repositoryStore: RepositoryStore
  let deploymentStore: DeploymentStore
  let privacyMonetizationStore: PrivacyMonetizationStore
  let siteMaintenanceStore: SiteMaintenanceStore
  let persistenceStore: WorkbenchPersistenceStore
  let repositoryDeploymentCoordinator: RepositoryDeploymentCoordinator

  public lazy var ai: WorkbenchAIFeatureFacade = WorkbenchAIFeatureFacade(store: self)
  public lazy var repository: WorkbenchRepositoryFeatureFacade = WorkbenchRepositoryFeatureFacade(store: self)
  public lazy var publishing: WorkbenchPublishingFeatureFacade = WorkbenchPublishingFeatureFacade(store: self)
  public lazy var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade = WorkbenchImageWorkbenchFeatureFacade(store: self)
  public lazy var persistenceStatus: WorkbenchPersistenceFeatureFacade = WorkbenchPersistenceFeatureFacade(store: self)
  public lazy var shell: WorkbenchShellFeatureFacade = WorkbenchShellFeatureFacade(store: self)
  @Published public private(set) var contentHealthSnapshotVersion = 0
  @Published public private(set) var draftTaskQueueStateVersion = 0
  private var draftTaskQueueStateCache: [UUID: DraftTaskQueueState] = [:]
  private var imageWorkbenchSiteSummaryVersion = 0
  private var imageWorkbenchSiteSummaryCache: (version: Int, summary: ImageWorkbenchSiteSummary)?
  private var childStoreCancellables = Set<AnyCancellable>()
  var preflightRefreshTask: Task<Void, Never>?
  var draftBodyCommitTasks: [UUID: Task<Void, Never>] = [:]

  lazy var aiStore: WorkbenchAIStore = WorkbenchAIStore(
    store: self,
    workspace: aiWorkspaceStore,
    aiPublishingAssistantService: aiPublishingAssistantService,
    keychainTokenStore: keychainTokenStore,
    aiConnectionTestService: aiConnectionTestService,
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
  public var activeProfileID: UUID { publishingStore.activeProfileID }
  public var drafts: [ArticleDraft] { publishingStore.drafts }
  public var repositoryReport: RepositoryScanReport? { repositoryStore.repositoryReport }
  public var imageWorkbenchReport: ImageWorkbenchReport? { publishingStore.imageWorkbenchReport }

  public init(
    persistence: WorkbenchPersistence = WorkbenchPersistence(),
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
    localSitePreviewProcessService: LocalSitePreviewProcessService = LocalSitePreviewProcessService(),
    contentPerformanceCSVImportService: ContentPerformanceCSVImportService = ContentPerformanceCSVImportService(),
    remoteReviewDraftBuilder: RemoteReviewDraftBuilder = RemoteReviewDraftBuilder(),
    localGitPublishService: LocalGitPublishService = LocalGitPublishService(),
    remoteRepositoryPublishService: RemoteRepositoryPublishService = RemoteRepositoryPublishService(),
    deploymentStatusService: DeploymentStatusService = DeploymentStatusService(),
    deploymentWebhookService: DeploymentWebhookService = DeploymentWebhookService(),
    siteStarterService: SiteStarterService = SiteStarterService(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    seoAuditService: SEOAuditService = SEOAuditService(),
    seoSocialPreviewService: SEOSocialPreviewService = SEOSocialPreviewService(),
    siteMaintenanceService: SiteMaintenanceService = SiteMaintenanceService(),
    releaseLedgerService: ReleaseLedgerService = ReleaseLedgerService(),
    generalDraftLibraryService: GeneralDraftLibraryService = GeneralDraftLibraryService(),
    monetizationService: MonetizationService = MonetizationService(),
    releaseQualityGateService: ReleaseQualityGateService = ReleaseQualityGateService(),
    keychainTokenStore: KeychainTokenStore = KeychainTokenStore(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(service: "PersonalSitePublisherMac.RepositoryProvider", accountPrefix: "repository-provider"),
    deploymentTokenStore: KeychainTokenStore = KeychainTokenStore(service: "PersonalSitePublisherMac.DeploymentProvider", accountPrefix: "deployment-provider"),
    aiPublishingAssistantService: AIPublishingAssistantService = AIPublishingAssistantService(),
    aiConnectionTestService: AIConnectionTestService = AIConnectionTestService()
  ) {
    self.persistenceStore = WorkbenchPersistenceStore(persistence: persistence)
    self.imageWorkbenchService = imageWorkbenchService
    self.keychainTokenStore = keychainTokenStore
    self.aiPublishingAssistantService = aiPublishingAssistantService
    self.aiConnectionTestService = aiConnectionTestService
    self.seoAuditService = seoAuditService
    self.seoSocialPreviewService = seoSocialPreviewService
    self.siteMaintenanceStore = SiteMaintenanceStore()

    let snapshotLoad: WorkbenchSnapshotLoadResult
    do {
      snapshotLoad = try persistenceStore.loadWithRecovery()
    } catch {
      snapshotLoad = WorkbenchSnapshotLoadResult(
        snapshot: nil,
        recoveryMessage: "工作台数据无法读取，已使用空白工作台启动。原始文件未被覆盖：\(error.localizedDescription)"
      )
    }
    let snapshot = snapshotLoad.snapshot
    let snapshotProfiles = snapshot?.profiles ?? []
    let initialProfiles = snapshotProfiles.isEmpty ? [SiteProfile.defaultProfile] : snapshotProfiles
    let initialActiveProfileID = snapshot?.activeProfileID ?? initialProfiles.first?.id ?? SiteProfile.defaultProfileID
    let activeProfile = initialProfiles.first { $0.id == initialActiveProfileID } ?? initialProfiles[0]
    let snapshotDrafts = snapshot?.drafts ?? []
    let initialDrafts = snapshotDrafts.isEmpty ? [ArticleDraft.empty(profile: activeProfile)] : snapshotDrafts

    self.privacyMonetizationStore = PrivacyMonetizationStore(
      privacySettings: snapshot?.privacySettings ?? .default,
      privacyProtectionEvents: snapshot?.privacyProtectionEvents ?? [],
      monetizationState: snapshot?.monetizationState ?? .default,
      monetizationService: monetizationService
    )
    self.repositoryStore = RepositoryStore(
      remoteRepositoryAccessCheck: snapshot?.remoteRepositoryAccessCheck,
      repositoryAutoSyncSettings: snapshot?.repositoryAutoSyncSettings ?? .default,
      repositoryAutoSyncState: snapshot?.repositoryAutoSyncState ?? .idle,
      repositoryService: repositoryService,
      repositoryTokenStore: repositoryTokenStore,
      remoteRepositoryPublishService: remoteRepositoryPublishService,
      repositorySyncCommandBuilder: repositorySyncCommandBuilder
    )
    self.deploymentStore = DeploymentStore(
      deploymentStatusSnapshots: Dictionary(uniqueKeysWithValues: (snapshot?.deploymentStatusSnapshots ?? []).compactMap { snapshot in
        snapshot.releaseRecordID.map { ($0, snapshot) }
      }),
      deploymentStatusHistory: snapshot?.deploymentStatusHistory ?? [:],
      deploymentPollingSettings: snapshot?.deploymentPollingSettings ?? .default,
      deploymentPollingState: snapshot?.deploymentPollingState ?? .idle,
      deploymentStatusService: deploymentStatusService,
      deploymentWebhookService: deploymentWebhookService,
      deploymentTokenStore: deploymentTokenStore,
      legacyRepositoryTokenStore: repositoryTokenStore,
      releaseLedgerService: releaseLedgerService
    )
    self.repositoryDeploymentCoordinator = RepositoryDeploymentCoordinator(
      repositoryStore: repositoryStore,
      deploymentStore: deploymentStore
    )
    self.aiWorkspaceStore = AIWorkspaceStore(
      aiMetadataApplicationRecords: snapshot?.aiMetadataApplicationRecords ?? [],
      aiChatCustomPrompts: snapshot?.aiChatCustomPrompts ?? [],
      seoSocialPreviewSnapshots: Dictionary(uniqueKeysWithValues: (snapshot?.seoSocialPreviewSnapshots ?? []).map { ($0.draftID, $0) })
    )
    self.publishingStore = PublishingStore(
      profiles: initialProfiles,
      activeProfileID: initialActiveProfileID,
      drafts: initialDrafts,
      releaseRecords: snapshot?.releaseRecords ?? [],
      selectedDraftID: initialDrafts.first?.id,
      externalVerificationEvidenceRecords: snapshot?.externalVerificationEvidenceRecords ?? [],
      maintenanceOperationRecords: snapshot?.maintenanceOperationRecords ?? [],
      contentPerformanceSnapshots: snapshot?.contentPerformanceSnapshots ?? [],
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
      contentPerformanceCSVImportService: contentPerformanceCSVImportService,
      siteMaintenanceService: siteMaintenanceService,
      releaseQualityGateService: releaseQualityGateService
    )
    publishingStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    repositoryStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    deploymentStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStoreCancellables)
    privacyMonetizationStore.objectWillChange
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
    aiStore.replaceAIChatSessions(
      persistenceStore.persistence.hydratedAIChatSessions(snapshot?.aiChatSessionsByDraftID ?? [:])
    )
    repositoryDeploymentCoordinator.refreshTokenAvailability(store: self)
    privacyMonetizationStore.showPrivacyMaskIfNeededOnLaunch()
    if let recoveryMessage = snapshotLoad.recoveryMessage {
      persistenceStore.setRecoveryMessage(recoveryMessage)
      setLastSaveStatus("需要检查工作台数据")
    }
    runPreflight()
    refreshPublishPreview(for: selectedDraft)
    aiStore.restoreSEOSocialPreviewSnapshotForCurrentSelection()
  }

  public var activeProfile: SiteProfile { publishingStore.activeProfile }

  public var selectedDraft: ArticleDraft? { publishingStore.selectedDraft }

  public var visibleDrafts: [ArticleDraft] { publishingStore.visibleDrafts }

  public func profile(for draft: ArticleDraft) -> SiteProfile { publishingStore.profile(for: draft) }

  public func profile(for record: ReleaseRecord) -> SiteProfile { publishingStore.profile(for: record) }

  func profile(for package: PublishPackage) -> SiteProfile { publishingStore.profile(for: package) }

  public func save() {
    flushDraftBodyEditorBuffers()
    persistenceStore.saveImmediately(snapshot: persistenceStore.persistence.snapshot(from: self))
  }

  /// Saves immediately and reports whether it is safe to let the process exit.
  @discardableResult
  public func flushPendingChanges() -> Bool {
    flushDraftBodyEditorBuffers()
    return persistenceStore.flush(snapshot: persistenceStore.persistence.snapshot(from: self))
  }

  func scheduleAutosave() {
    persistenceStore.scheduleAutosave { [weak self] in
      guard let self else { return nil }
      return self.persistenceStore.persistence.snapshot(from: self)
    }
  }

  func invalidateDraftDerivedCaches() {
    invalidateContentHealthSnapshot()
    invalidateSiteMaintenanceSnapshot()
    invalidateDraftTaskQueueStateCache()
  }

  func invalidateBodyEditingDerivedCaches(for draftID: UUID) {
    // Body typing does not alter images, release history, or maintenance
    // metadata. Keep those expensive summaries warm until a debounced
    // preflight refresh runs.
    invalidateContentHealthSnapshot()
    draftTaskQueueStateCache.removeValue(forKey: draftID)
    draftTaskQueueStateVersion += 1
  }

  private func invalidateContentHealthSnapshot() {
    contentHealthSnapshotVersion += 1
  }

  func invalidateDraftTaskQueueStateCache() {
    invalidateImageWorkbenchSiteSummaryCache()
    draftTaskQueueStateCache.removeAll()
    draftTaskQueueStateVersion += 1
  }

  private func invalidateImageWorkbenchSiteSummaryCache() {
    imageWorkbenchSiteSummaryCache = nil
    imageWorkbenchSiteSummaryVersion += 1
  }

  func invalidateSiteMaintenanceSnapshot() {
    siteMaintenanceStore.invalidate()
  }

  public var imageWorkbenchSiteSummary: ImageWorkbenchSiteSummary {
    let version = imageWorkbenchSiteSummaryVersion
    if let cached = imageWorkbenchSiteSummaryCache, cached.version == version {
      return cached.summary
    }

    let summary = imageWorkbenchService.siteSummary(drafts: visibleDrafts, profile: activeProfile)
    imageWorkbenchSiteSummaryCache = (version, summary)
    return summary
  }

  public func draftTaskQueueStates(for drafts: [ArticleDraft]) -> [UUID: DraftTaskQueueState] {
    let imageIssueCounts = Dictionary(
      uniqueKeysWithValues: imageWorkbenchSiteSummary.draftSummaries.map { summary in
        (summary.draftID, summary.issueCount)
      }
    )
    let repositoryReadinessFingerprint = [
      repositoryReport?.rootPath ?? "",
      repositoryReport?.statusTitle ?? "",
      repositoryReport?.syncStatusTitle ?? "",
      "\(repositoryReport?.changedFiles.count ?? 0)",
      "\(repositoryReport?.remoteChangedFiles.count ?? 0)"
    ].joined(separator: "|")
    let draftIDs = Set(drafts.map(\.id))
    draftTaskQueueStateCache = draftTaskQueueStateCache.filter { draftIDs.contains($0.key) }

    return Dictionary(
      uniqueKeysWithValues: drafts.map { draft in
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
          hasPreflightErrors: preflightIssues(for: draft).contains { $0.severity == .error },
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

  func replaceSiteMaintenanceSnapshot(report: SiteMaintenanceReport) {
    siteMaintenanceStore.replaceSnapshot(
      report: report,
      profileID: activeProfileID,
      profileName: activeProfile.name,
      draftCount: visibleDrafts.count
    )
  }
}
