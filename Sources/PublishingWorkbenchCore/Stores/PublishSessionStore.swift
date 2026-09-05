import Combine
import Foundation

/// Owns state that exists only while preparing, previewing, or completing a
/// publish operation. `PublishingStore` keeps compatibility accessors while
/// feature facades migrate to this narrower observation boundary.
@MainActor
public final class PublishSessionStore: ObservableObject {
  @Published public internal(set) var releaseRecords: [ReleaseRecord]
  @Published public internal(set) var publishPackage: PublishPackage?
  @Published public internal(set) var localPublishPreview: LocalPublishPreview?
  @Published public internal(set) var localPublishReadiness: LocalPublishReadiness?
  @Published public internal(set) var isPublishPreviewRefreshing: Bool
  @Published public internal(set) var remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview?
  @Published public internal(set) var batchPublishPlan: BatchPublishPlan?
  @Published public internal(set) var isBatchPublishPlanRefreshing: Bool
  @Published public internal(set) var batchRemotePublishPreviewSnapshot:
    RemoteRepositoryPublishPreview?
  @Published public internal(set) var remoteRepositoryConflictSession:
    RemoteRepositoryConflictSession?
  @Published public internal(set) var localSitePreviewPlan: LocalSitePreviewPlan?
  @Published public internal(set) var localSitePreviewRuntimeStatus: LocalSitePreviewRuntimeStatus
  @Published public internal(set) var localSitePreviewRefreshToken: UInt64
  @Published public internal(set) var remoteReviewDraft: RemoteReviewDraft?
  @Published public internal(set) var batchRemoteReviewDraft: RemoteReviewDraft?
  @Published public internal(set) var preflightIssues: [PreflightIssue]
  @Published public internal(set) var publishActionFeedback: PublishActionFeedback?
  @Published public internal(set) var isLocalRepositoryMutationRunning: Bool

  var localRepositoryMutationContext: LocalRepositoryOperationContext?
  var remoteRepositoryMutationContext: RemoteRepositoryOperationContext?
  var remoteConflictResolutionOperationID: UUID?
  var localImportOperationContext: LocalRepositoryOperationContext?
  var localSitePreviewStopTask: Task<Void, Never>?
  var localSitePreviewStopOperationID: UUID?
  var localSitePreviewGeneration: UInt64 = 0
  var localSitePreviewFileWatcher: LocalSitePreviewFileWatcher?
  var draftPublishPreviewSnapshots: [UUID: DraftPublishPreviewSnapshot] = [:]
  var draftPublishPreviewInputBaselines: [UUID: DraftPublishPreviewInputBaseline] = [:]
  var draftPublishPreviewRefreshTasks: [UUID: Task<Void, Never>] = [:]
  var draftPublishPreviewRefreshGenerations: [UUID: UInt64] = [:]
  var publishPreviewRefreshTask: Task<Void, Never>?
  var publishPreviewRefreshGeneration: UInt64 = 0
  var batchPublishPlanRefreshTask: Task<Void, Never>?
  var batchPublishPlanRefreshGeneration: UInt64 = 0

  init(
    releaseRecords: [ReleaseRecord],
    publishPackage: PublishPackage?,
    localPublishPreview: LocalPublishPreview?,
    localPublishReadiness: LocalPublishReadiness?,
    remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview?,
    batchPublishPlan: BatchPublishPlan?,
    batchRemotePublishPreviewSnapshot: RemoteRepositoryPublishPreview?,
    localSitePreviewPlan: LocalSitePreviewPlan?,
    localSitePreviewRuntimeStatus: LocalSitePreviewRuntimeStatus,
    remoteReviewDraft: RemoteReviewDraft?,
    batchRemoteReviewDraft: RemoteReviewDraft?,
    preflightIssues: [PreflightIssue],
    publishActionFeedback: PublishActionFeedback?
  ) {
    self.releaseRecords = ReleaseRecord.limitedHistory(releaseRecords)
    self.publishPackage = publishPackage
    self.localPublishPreview = localPublishPreview
    self.localPublishReadiness = localPublishReadiness
    self.isPublishPreviewRefreshing = false
    self.remotePublishPreviewSnapshot = remotePublishPreviewSnapshot
    self.batchPublishPlan = batchPublishPlan
    self.isBatchPublishPlanRefreshing = false
    self.batchRemotePublishPreviewSnapshot = batchRemotePublishPreviewSnapshot
    self.remoteRepositoryConflictSession = nil
    self.localSitePreviewPlan = localSitePreviewPlan
    self.localSitePreviewRuntimeStatus = localSitePreviewRuntimeStatus
    self.localSitePreviewRefreshToken = 0
    self.remoteReviewDraft = remoteReviewDraft
    self.batchRemoteReviewDraft = batchRemoteReviewDraft
    self.preflightIssues = preflightIssues
    self.publishActionFeedback = publishActionFeedback
    self.isLocalRepositoryMutationRunning = false
  }
}

/// Owns the transient lifecycle of the site-creation wizard independently of
/// draft editing and ordinary publishing state.
@MainActor
public final class SiteStarterStore: ObservableObject {
  let service: SiteStarterService
  var operationGeneration: UInt64 = 0

  @Published public internal(set) var result: SiteStarterResult?
  @Published public internal(set) var importResult: SiteStarterImportResult?
  @Published public internal(set) var pushResult: SiteStarterPushResult?
  @Published public internal(set) var isOperationRunning: Bool

  init(
    service: SiteStarterService,
    result: SiteStarterResult?,
    importResult: SiteStarterImportResult?,
    pushResult: SiteStarterPushResult?
  ) {
    self.service = service
    self.result = result
    self.importResult = importResult
    self.pushResult = pushResult
    self.isOperationRunning = false
  }
}
