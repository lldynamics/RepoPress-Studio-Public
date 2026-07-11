import Combine
import Foundation

public struct RecentlyDeletedProfile: Sendable {
  public let profile: SiteProfile
  public let drafts: [ArticleDraft]
  public let deletedAt: Date

  public var draftCount: Int { drafts.count }
}

extension PublishingStore {
  func repositoryAccessToken(for profile: SiteProfile) throws -> String? {
    try repositoryTokenStore.repositoryToken(for: profile)
  }

  func beginLocalRepositoryMutation(profile: SiteProfile) -> LocalRepositoryOperationContext? {
    guard localRepositoryMutationContext == nil else { return nil }
    let context = LocalRepositoryOperationContext(profile: profile)
    localRepositoryMutationContext = context
    isLocalRepositoryMutationRunning = true
    return context
  }

  func finishLocalRepositoryMutation(_ context: LocalRepositoryOperationContext) {
    guard localRepositoryMutationContext == context else { return }
    localRepositoryMutationContext = nil
    isLocalRepositoryMutationRunning = false
  }

  func beginRemoteRepositoryMutation(profile: SiteProfile, store: WorkbenchStore) -> RemoteRepositoryOperationContext? {
    guard remoteRepositoryMutationContext == nil else { return nil }
    let context = RemoteRepositoryOperationContext(profile: profile)
    remoteRepositoryMutationContext = context
    store.setRemoteRepositoryPublishing(true)
    return context
  }

  func remoteRepositoryMutationIsCurrent(
    _ context: RemoteRepositoryOperationContext,
    store: WorkbenchStore
  ) -> Bool {
    remoteRepositoryMutationContext == context
      && context.stillMatches(store.profiles.first(where: { $0.id == context.profileID }))
  }

  func finishRemoteRepositoryMutation(_ context: RemoteRepositoryOperationContext, store: WorkbenchStore) {
    guard remoteRepositoryMutationContext == context else { return }
    remoteRepositoryMutationContext = nil
    store.setRemoteRepositoryPublishing(false)
  }
}

@MainActor
public final class PublishingStore: ObservableObject {
  let preflightService: PreflightCheckService
  let publishPackageBuilder: PublishPackageBuilder
  let localPublishPreviewService: LocalPublishPreviewService
  let batchPublishPlanService: BatchPublishPlanService
  let remoteRepositoryPublishService: RemoteRepositoryPublishService
  let repositoryTokenStore: KeychainTokenStore
  let localGitPublishService: LocalGitPublishService
  let remoteReviewDraftBuilder: RemoteReviewDraftBuilder
  let batchPublishCommandBuilder: BatchPublishCommandBuilder
  let remotePublishRiskService: RemotePublishRiskService
  let localContentImportService: LocalContentImportService
  let contentMigrationService: ContentMigrationService
  let siteStarterService: SiteStarterService
  let generalDraftLibraryService: GeneralDraftLibraryService
  let localSitePreviewService: LocalSitePreviewService
  let localSitePreviewProcessService: LocalSitePreviewProcessService
  let contentPerformanceCSVImportService: ContentPerformanceCSVImportService
  let siteMaintenanceService: SiteMaintenanceService
  let releaseQualityGateService: ReleaseQualityGateService
  var localRepositoryMutationContext: LocalRepositoryOperationContext?
  var remoteRepositoryMutationContext: RemoteRepositoryOperationContext?
  var localImportOperationContext: LocalRepositoryOperationContext?
  var localSitePreviewStopTask: Task<Void, Never>?
  var localSitePreviewStopOperationID: UUID?
  var localSitePreviewGeneration: UInt64 = 0

  @Published public internal(set) var profiles: [SiteProfile]
  @Published public internal(set) var activeProfileID: UUID
  @Published public internal(set) var drafts: [ArticleDraft]
  @Published public internal(set) var releaseRecords: [ReleaseRecord]
  @Published public internal(set) var selectedSection: WorkspaceSection
  @Published public internal(set) var selectedDraftID: UUID?
  @Published public internal(set) var publishPackage: PublishPackage?
  @Published public internal(set) var localPublishPreview: LocalPublishPreview?
  @Published public internal(set) var localPublishReadiness: LocalPublishReadiness?
  /// The last explicitly refreshed remote preview for the selected article.
  /// Views render this snapshot instead of rebuilding a package and diff from `body`.
  @Published public internal(set) var remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview?
  @Published public internal(set) var batchPublishPlan: BatchPublishPlan?
  /// The last explicitly refreshed remote preview for the batch publish plan.
  @Published public internal(set) var batchRemotePublishPreviewSnapshot: RemoteRepositoryPublishPreview?
  @Published public internal(set) var localSitePreviewPlan: LocalSitePreviewPlan?
  @Published public internal(set) var localSitePreviewRuntimeStatus: LocalSitePreviewRuntimeStatus
  @Published public internal(set) var remoteReviewDraft: RemoteReviewDraft?
  @Published public internal(set) var batchRemoteReviewDraft: RemoteReviewDraft?
  @Published public internal(set) var siteStarterResult: SiteStarterResult?
  @Published public internal(set) var siteStarterImportResult: SiteStarterImportResult?
  @Published public internal(set) var siteStarterPushResult: SiteStarterPushResult?
  @Published public internal(set) var imageWorkbenchReport: ImageWorkbenchReport?
  @Published public internal(set) var preflightIssues: [PreflightIssue]
  @Published public internal(set) var releaseQualityGateReport: ReleaseQualityGateReport
  @Published public internal(set) var releaseQualityGateMessage: String?
  @Published public internal(set) var externalVerificationEvidenceRecords: [ReleaseExternalVerificationEvidenceRecord]
  @Published public internal(set) var isInspectorPresented: Bool
  @Published public internal(set) var editorDisplayMode: EditorDisplayMode
  @Published public internal(set) var editorFocusRequest: EditorFocusRequest?
  public internal(set) var draftBodyEditorBuffers: [UUID: DraftBodyEditorBuffer] = [:]
  let draftBodyEditorBufferWillChange = PassthroughSubject<Void, Never>()
  @Published public internal(set) var activeEditorSelection: ActiveEditorSelection?
  @Published public internal(set) var automaticallyRefreshPreflightOnEdit: Bool
  @Published public internal(set) var lastSaveStatus: String
  @Published public internal(set) var publishActionMessage: String?
  @Published public internal(set) var isLocalRepositoryMutationRunning = false
  @Published public internal(set) var imageActionMessage: String?
  @Published public internal(set) var maintenanceOperationRecords: [MaintenanceOperationRecord]
  @Published public internal(set) var contentPerformanceSnapshots: [ContentPerformanceSnapshot]
  @Published public internal(set) var latestGeneralDraftReusePlan: GeneralDraftReusePlan?
  @Published public internal(set) var latestGeneralDraftBackupWriteResult: GeneralDraftBackupWriteResult?
  @Published public internal(set) var recentlyDeletedProfile: RecentlyDeletedProfile?

  func setDraftBodyEditorBuffer(_ buffer: DraftBodyEditorBuffer, for draftID: UUID) {
    guard draftBodyEditorBuffers[draftID] != buffer else { return }
    draftBodyEditorBufferWillChange.send()
    draftBodyEditorBuffers[draftID] = buffer
  }

  func removeDraftBodyEditorBuffer(for draftID: UUID) {
    guard draftBodyEditorBuffers[draftID] != nil else { return }
    draftBodyEditorBufferWillChange.send()
    draftBodyEditorBuffers.removeValue(forKey: draftID)
  }

  init(
    profiles: [SiteProfile],
    activeProfileID: UUID,
    drafts: [ArticleDraft],
    releaseRecords: [ReleaseRecord],
    selectedSection: WorkspaceSection = .writing,
    selectedDraftID: UUID? = nil,
    publishPackage: PublishPackage? = nil,
    localPublishPreview: LocalPublishPreview? = nil,
    localPublishReadiness: LocalPublishReadiness? = nil,
    remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview? = nil,
    batchPublishPlan: BatchPublishPlan? = nil,
    batchRemotePublishPreviewSnapshot: RemoteRepositoryPublishPreview? = nil,
    localSitePreviewPlan: LocalSitePreviewPlan? = nil,
    localSitePreviewRuntimeStatus: LocalSitePreviewRuntimeStatus = .stopped,
    remoteReviewDraft: RemoteReviewDraft? = nil,
    batchRemoteReviewDraft: RemoteReviewDraft? = nil,
    siteStarterResult: SiteStarterResult? = nil,
    siteStarterImportResult: SiteStarterImportResult? = nil,
    siteStarterPushResult: SiteStarterPushResult? = nil,
    imageWorkbenchReport: ImageWorkbenchReport? = nil,
    preflightIssues: [PreflightIssue] = [],
    releaseQualityGateReport: ReleaseQualityGateReport = .empty,
    releaseQualityGateMessage: String? = nil,
    externalVerificationEvidenceRecords: [ReleaseExternalVerificationEvidenceRecord] = [],
    isInspectorPresented: Bool = true,
    editorDisplayMode: EditorDisplayMode = .edit,
    editorFocusRequest: EditorFocusRequest? = nil,
    activeEditorSelection: ActiveEditorSelection? = nil,
    automaticallyRefreshPreflightOnEdit: Bool = true,
    lastSaveStatus: String = "尚未保存",
    publishActionMessage: String? = nil,
    imageActionMessage: String? = nil,
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    contentPerformanceSnapshots: [ContentPerformanceSnapshot] = [],
    latestGeneralDraftReusePlan: GeneralDraftReusePlan? = nil,
    latestGeneralDraftBackupWriteResult: GeneralDraftBackupWriteResult? = nil,
    recentlyDeletedProfile: RecentlyDeletedProfile? = nil,
    preflightService: PreflightCheckService = PreflightCheckService(),
    publishPackageBuilder: PublishPackageBuilder = PublishPackageBuilder(),
    localPublishPreviewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    batchPublishPlanService: BatchPublishPlanService = BatchPublishPlanService(),
    remoteRepositoryPublishService: RemoteRepositoryPublishService = RemoteRepositoryPublishService(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(service: "PersonalSitePublisher.Repository"),
    localGitPublishService: LocalGitPublishService = LocalGitPublishService(),
    remoteReviewDraftBuilder: RemoteReviewDraftBuilder = RemoteReviewDraftBuilder(),
    batchPublishCommandBuilder: BatchPublishCommandBuilder = BatchPublishCommandBuilder(),
    remotePublishRiskService: RemotePublishRiskService = RemotePublishRiskService(),
    localContentImportService: LocalContentImportService = LocalContentImportService(),
    contentMigrationService: ContentMigrationService = ContentMigrationService(),
    siteStarterService: SiteStarterService = SiteStarterService(),
    generalDraftLibraryService: GeneralDraftLibraryService = GeneralDraftLibraryService(),
    localSitePreviewService: LocalSitePreviewService = LocalSitePreviewService(),
    localSitePreviewProcessService: LocalSitePreviewProcessService = LocalSitePreviewProcessService(),
    contentPerformanceCSVImportService: ContentPerformanceCSVImportService = ContentPerformanceCSVImportService(),
    siteMaintenanceService: SiteMaintenanceService = SiteMaintenanceService(),
    releaseQualityGateService: ReleaseQualityGateService = ReleaseQualityGateService()
  ) {
    self.preflightService = preflightService
    self.publishPackageBuilder = publishPackageBuilder
    self.localPublishPreviewService = localPublishPreviewService
    self.batchPublishPlanService = batchPublishPlanService
    self.remoteRepositoryPublishService = remoteRepositoryPublishService
    self.repositoryTokenStore = repositoryTokenStore
    self.localGitPublishService = localGitPublishService
    self.remoteReviewDraftBuilder = remoteReviewDraftBuilder
    self.batchPublishCommandBuilder = batchPublishCommandBuilder
    self.remotePublishRiskService = remotePublishRiskService
    self.localContentImportService = localContentImportService
    self.contentMigrationService = contentMigrationService
    self.siteStarterService = siteStarterService
    self.generalDraftLibraryService = generalDraftLibraryService
    self.localSitePreviewService = localSitePreviewService
    self.localSitePreviewProcessService = localSitePreviewProcessService
    self.contentPerformanceCSVImportService = contentPerformanceCSVImportService
    self.siteMaintenanceService = siteMaintenanceService
    self.releaseQualityGateService = releaseQualityGateService
    self.profiles = profiles
    self.activeProfileID = activeProfileID
    self.drafts = drafts
    self.releaseRecords = releaseRecords
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    self.publishPackage = publishPackage
    self.localPublishPreview = localPublishPreview
    self.localPublishReadiness = localPublishReadiness
    self.remotePublishPreviewSnapshot = remotePublishPreviewSnapshot
    self.batchPublishPlan = batchPublishPlan
    self.batchRemotePublishPreviewSnapshot = batchRemotePublishPreviewSnapshot
    self.localSitePreviewPlan = localSitePreviewPlan
    self.localSitePreviewRuntimeStatus = localSitePreviewRuntimeStatus
    self.remoteReviewDraft = remoteReviewDraft
    self.batchRemoteReviewDraft = batchRemoteReviewDraft
    self.siteStarterResult = siteStarterResult
    self.siteStarterImportResult = siteStarterImportResult
    self.siteStarterPushResult = siteStarterPushResult
    self.imageWorkbenchReport = imageWorkbenchReport
    self.preflightIssues = preflightIssues
    self.releaseQualityGateReport = releaseQualityGateReport
    self.releaseQualityGateMessage = releaseQualityGateMessage
    self.externalVerificationEvidenceRecords = externalVerificationEvidenceRecords
    self.isInspectorPresented = isInspectorPresented
    self.editorDisplayMode = editorDisplayMode
    self.editorFocusRequest = editorFocusRequest
    self.activeEditorSelection = activeEditorSelection
    self.automaticallyRefreshPreflightOnEdit = automaticallyRefreshPreflightOnEdit
    self.lastSaveStatus = lastSaveStatus
    self.publishActionMessage = publishActionMessage
    self.imageActionMessage = imageActionMessage
    self.maintenanceOperationRecords = maintenanceOperationRecords
    self.contentPerformanceSnapshots = contentPerformanceSnapshots
    self.latestGeneralDraftReusePlan = latestGeneralDraftReusePlan
    self.latestGeneralDraftBackupWriteResult = latestGeneralDraftBackupWriteResult
    self.recentlyDeletedProfile = recentlyDeletedProfile
  }

}
