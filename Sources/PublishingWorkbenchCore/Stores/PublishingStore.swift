import Combine
import Foundation

public struct RecentlyDeletedProfile: Sendable {
  public let profile: SiteProfile
  public let drafts: [ArticleDraft]
  public let deletedAt: Date

  public var draftCount: Int { drafts.count }
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
  let siteStarterService: SiteStarterService
  let generalDraftLibraryService: GeneralDraftLibraryService
  let localSitePreviewService: LocalSitePreviewService
  let localSitePreviewProcessService: LocalSitePreviewProcessService
  let siteMaintenanceService: SiteMaintenanceService
  let releaseQualityGateService: ReleaseQualityGateService

  @Published public internal(set) var profiles: [SiteProfile]
  @Published public internal(set) var activeProfileID: UUID
  @Published public internal(set) var drafts: [ArticleDraft]
  @Published public internal(set) var releaseRecords: [ReleaseRecord]
  @Published public internal(set) var selectedSection: WorkspaceSection
  @Published public internal(set) var selectedDraftID: UUID?
  @Published public internal(set) var publishPackage: PublishPackage?
  @Published public internal(set) var localPublishPreview: LocalPublishPreview?
  @Published public internal(set) var localPublishReadiness: LocalPublishReadiness?
  @Published public internal(set) var batchPublishPlan: BatchPublishPlan?
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
  @Published public internal(set) var activeEditorSelection: ActiveEditorSelection?
  @Published public internal(set) var automaticallyRefreshPreflightOnEdit: Bool
  @Published public internal(set) var lastSaveStatus: String
  @Published public internal(set) var publishActionMessage: String?
  @Published public internal(set) var imageActionMessage: String?
  @Published public internal(set) var maintenanceOperationRecords: [MaintenanceOperationRecord]
  @Published public internal(set) var contentPerformanceSnapshots: [ContentPerformanceSnapshot]
  @Published public internal(set) var latestGeneralDraftReusePlan: GeneralDraftReusePlan?
  @Published public internal(set) var latestGeneralDraftBackupWriteResult: GeneralDraftBackupWriteResult?
  @Published public internal(set) var recentlyDeletedProfile: RecentlyDeletedProfile?

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
    batchPublishPlan: BatchPublishPlan? = nil,
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
    siteStarterService: SiteStarterService = SiteStarterService(),
    generalDraftLibraryService: GeneralDraftLibraryService = GeneralDraftLibraryService(),
    localSitePreviewService: LocalSitePreviewService = LocalSitePreviewService(),
    localSitePreviewProcessService: LocalSitePreviewProcessService = LocalSitePreviewProcessService(),
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
    self.siteStarterService = siteStarterService
    self.generalDraftLibraryService = generalDraftLibraryService
    self.localSitePreviewService = localSitePreviewService
    self.localSitePreviewProcessService = localSitePreviewProcessService
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
    self.batchPublishPlan = batchPublishPlan
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
