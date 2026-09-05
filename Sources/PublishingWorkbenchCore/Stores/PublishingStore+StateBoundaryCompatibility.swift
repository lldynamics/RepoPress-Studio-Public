import Foundation

extension PublishingStore {
  public internal(set) var releaseRecords: [ReleaseRecord] {
    get { publishSession.releaseRecords }
    set { publishSession.releaseRecords = newValue }
  }

  public internal(set) var publishPackage: PublishPackage? {
    get { publishSession.publishPackage }
    set { publishSession.publishPackage = newValue }
  }

  public internal(set) var localPublishPreview: LocalPublishPreview? {
    get { publishSession.localPublishPreview }
    set { publishSession.localPublishPreview = newValue }
  }

  public internal(set) var localPublishReadiness: LocalPublishReadiness? {
    get { publishSession.localPublishReadiness }
    set { publishSession.localPublishReadiness = newValue }
  }

  public internal(set) var isPublishPreviewRefreshing: Bool {
    get { publishSession.isPublishPreviewRefreshing }
    set { publishSession.isPublishPreviewRefreshing = newValue }
  }

  public internal(set) var remotePublishPreviewSnapshot: RemoteRepositoryPublishPreview? {
    get { publishSession.remotePublishPreviewSnapshot }
    set { publishSession.remotePublishPreviewSnapshot = newValue }
  }

  public internal(set) var batchPublishPlan: BatchPublishPlan? {
    get { publishSession.batchPublishPlan }
    set { publishSession.batchPublishPlan = newValue }
  }

  public internal(set) var isBatchPublishPlanRefreshing: Bool {
    get { publishSession.isBatchPublishPlanRefreshing }
    set { publishSession.isBatchPublishPlanRefreshing = newValue }
  }

  public internal(set) var batchRemotePublishPreviewSnapshot: RemoteRepositoryPublishPreview? {
    get { publishSession.batchRemotePublishPreviewSnapshot }
    set { publishSession.batchRemotePublishPreviewSnapshot = newValue }
  }

  public internal(set) var remoteRepositoryConflictSession: RemoteRepositoryConflictSession? {
    get { publishSession.remoteRepositoryConflictSession }
    set { publishSession.remoteRepositoryConflictSession = newValue }
  }

  public internal(set) var localSitePreviewPlan: LocalSitePreviewPlan? {
    get { publishSession.localSitePreviewPlan }
    set { publishSession.localSitePreviewPlan = newValue }
  }

  public internal(set) var localSitePreviewRuntimeStatus: LocalSitePreviewRuntimeStatus {
    get { publishSession.localSitePreviewRuntimeStatus }
    set { publishSession.localSitePreviewRuntimeStatus = newValue }
  }

  public internal(set) var localSitePreviewRefreshToken: UInt64 {
    get { publishSession.localSitePreviewRefreshToken }
    set { publishSession.localSitePreviewRefreshToken = newValue }
  }

  public internal(set) var remoteReviewDraft: RemoteReviewDraft? {
    get { publishSession.remoteReviewDraft }
    set { publishSession.remoteReviewDraft = newValue }
  }

  public internal(set) var batchRemoteReviewDraft: RemoteReviewDraft? {
    get { publishSession.batchRemoteReviewDraft }
    set { publishSession.batchRemoteReviewDraft = newValue }
  }

  public internal(set) var preflightIssues: [PreflightIssue] {
    get { publishSession.preflightIssues }
    set { publishSession.preflightIssues = newValue }
  }

  public internal(set) var publishActionFeedback: PublishActionFeedback? {
    get { publishSession.publishActionFeedback }
    set { publishSession.publishActionFeedback = newValue }
  }

  public internal(set) var isLocalRepositoryMutationRunning: Bool {
    get { publishSession.isLocalRepositoryMutationRunning }
    set { publishSession.isLocalRepositoryMutationRunning = newValue }
  }

  var localRepositoryMutationContext: LocalRepositoryOperationContext? {
    get { publishSession.localRepositoryMutationContext }
    set { publishSession.localRepositoryMutationContext = newValue }
  }

  var remoteRepositoryMutationContext: RemoteRepositoryOperationContext? {
    get { publishSession.remoteRepositoryMutationContext }
    set { publishSession.remoteRepositoryMutationContext = newValue }
  }

  var remoteConflictResolutionOperationID: UUID? {
    get { publishSession.remoteConflictResolutionOperationID }
    set { publishSession.remoteConflictResolutionOperationID = newValue }
  }

  public var isRemoteConflictResolutionRunning: Bool {
    remoteConflictResolutionOperationID != nil
  }

  var localImportOperationContext: LocalRepositoryOperationContext? {
    get { publishSession.localImportOperationContext }
    set { publishSession.localImportOperationContext = newValue }
  }

  var localSitePreviewStopTask: Task<Void, Never>? {
    get { publishSession.localSitePreviewStopTask }
    set { publishSession.localSitePreviewStopTask = newValue }
  }

  var localSitePreviewStopOperationID: UUID? {
    get { publishSession.localSitePreviewStopOperationID }
    set { publishSession.localSitePreviewStopOperationID = newValue }
  }

  var localSitePreviewGeneration: UInt64 {
    get { publishSession.localSitePreviewGeneration }
    set { publishSession.localSitePreviewGeneration = newValue }
  }

  var localSitePreviewFileWatcher: LocalSitePreviewFileWatcher? {
    get { publishSession.localSitePreviewFileWatcher }
    set { publishSession.localSitePreviewFileWatcher = newValue }
  }

  var draftPublishPreviewSnapshots: [UUID: DraftPublishPreviewSnapshot] {
    get { publishSession.draftPublishPreviewSnapshots }
    set { publishSession.draftPublishPreviewSnapshots = newValue }
  }

  var draftPublishPreviewInputBaselines: [UUID: DraftPublishPreviewInputBaseline] {
    get { publishSession.draftPublishPreviewInputBaselines }
    set { publishSession.draftPublishPreviewInputBaselines = newValue }
  }

  var draftPublishPreviewRefreshTasks: [UUID: Task<Void, Never>] {
    get { publishSession.draftPublishPreviewRefreshTasks }
    set { publishSession.draftPublishPreviewRefreshTasks = newValue }
  }

  var draftPublishPreviewRefreshGenerations: [UUID: UInt64] {
    get { publishSession.draftPublishPreviewRefreshGenerations }
    set { publishSession.draftPublishPreviewRefreshGenerations = newValue }
  }

  var publishPreviewRefreshTask: Task<Void, Never>? {
    get { publishSession.publishPreviewRefreshTask }
    set { publishSession.publishPreviewRefreshTask = newValue }
  }

  var publishPreviewRefreshGeneration: UInt64 {
    get { publishSession.publishPreviewRefreshGeneration }
    set { publishSession.publishPreviewRefreshGeneration = newValue }
  }

  var batchPublishPlanRefreshTask: Task<Void, Never>? {
    get { publishSession.batchPublishPlanRefreshTask }
    set { publishSession.batchPublishPlanRefreshTask = newValue }
  }

  var batchPublishPlanRefreshGeneration: UInt64 {
    get { publishSession.batchPublishPlanRefreshGeneration }
    set { publishSession.batchPublishPlanRefreshGeneration = newValue }
  }

  var siteStarterService: SiteStarterService { siteStarter.service }

  var siteStarterOperationGeneration: UInt64 {
    get { siteStarter.operationGeneration }
    set { siteStarter.operationGeneration = newValue }
  }

  public internal(set) var siteStarterResult: SiteStarterResult? {
    get { siteStarter.result }
    set { siteStarter.result = newValue }
  }

  public internal(set) var siteStarterImportResult: SiteStarterImportResult? {
    get { siteStarter.importResult }
    set { siteStarter.importResult = newValue }
  }

  public internal(set) var siteStarterPushResult: SiteStarterPushResult? {
    get { siteStarter.pushResult }
    set { siteStarter.pushResult = newValue }
  }

  public internal(set) var isSiteStarterOperationRunning: Bool {
    get { siteStarter.isOperationRunning }
    set { siteStarter.isOperationRunning = newValue }
  }
}
