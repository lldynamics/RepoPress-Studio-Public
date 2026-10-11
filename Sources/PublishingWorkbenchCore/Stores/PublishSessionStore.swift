import Combine
import Foundation
import PublishingDomainContracts
import PublishingPreviewCore

/// Owns state that exists only while preparing, previewing, or completing a
/// publish operation. `PublishingStore` keeps compatibility accessors while
/// feature facades migrate to this narrower observation boundary.
@MainActor
public final class PublishSessionStore: ObservableObject {
  @Published public internal(set) var releaseRecords: [ReleaseRecord]
  @Published public internal(set) var executionRecords: [PublishExecutionRecord] = []
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
  var draftPublishPreviewSnapshots: [UUID: DraftPublishPreviewSnapshot] = [:] {
    didSet {
      if oldValue != draftPublishPreviewSnapshots { scheduleDraftPublishStatusNotification() }
    }
  }
  var draftPreflightSnapshots: [UUID: DraftPreflightSnapshot] = [:]
  var draftPreflightGenerations: [UUID: UInt64] = [:]
  var draftPreflightRefreshTasks: [UUID: DraftPreflightRefreshOperation] = [:]
  var draftPreflightAccessOrder: [UUID] = []
  /// The last installed result per draft. Unlike `draftPreflightSnapshots` it
  /// survives input invalidation, so while a refresh is pending the badge and
  /// checklist keep the previous complete result instead of a partial count.
  private(set) var draftPreflightLastKnownResults: [UUID: DraftPreflightResult] = [:]
  private var draftPreflightLastKnownOrder: [UUID] = []
  var draftPreflightGeneration: UInt64 = 0
  var draftPreflightRepositoryInputGeneration: UInt64 = 0
  var draftPreflightDraftInputGeneration: UInt64 = 0
  var isPublishingDerivedWordCount = false
  var draftPreflightInputCancellables = Set<AnyCancellable>()
  let draftPublishStatusDidChange = PassthroughSubject<Void, Never>()
  private var draftPublishStatusNotificationTask: Task<Void, Never>?
  var draftPublishPreviewInputBaselines: [UUID: DraftPublishPreviewInputBaseline] = [:]
  var draftPublishPreviewRefreshTasks: [UUID: Task<Void, Never>] = [:]
  var draftPublishPreviewRefreshGenerations: [UUID: UInt64] = [:]
  var publishPreviewRefreshTask: Task<Void, Never>?
  var publishPreviewRefreshGeneration: UInt64 = 0
  var batchPublishPlanRefreshTask: Task<Void, Never>?
  var batchPublishPlanRefreshGeneration: UInt64 = 0
  var batchPublishPlanRefreshInput: BatchPublishPlanRefreshInput?
  var batchPublishPlanConsumers: Set<UUID> = []

  /// Delivers cache notifications after the surrounding @Published willSet
  /// chain has committed its input. Background windows can then read the
  /// draft-scoped values without observing another window's selection.
  func scheduleDraftPublishStatusNotification() {
    guard draftPublishStatusNotificationTask == nil else { return }
    draftPublishStatusNotificationTask = Task { [weak self] in
      guard let self else { return }
      self.draftPublishStatusNotificationTask = nil
      self.draftPublishStatusDidChange.send()
    }
  }

  func rememberDraftPreflightResult(_ result: DraftPreflightResult) {
    let draftID = result.context.draftID
    draftPreflightLastKnownResults[draftID] = result
    draftPreflightLastKnownOrder.removeAll { $0 == draftID }
    draftPreflightLastKnownOrder.append(draftID)
    while draftPreflightLastKnownOrder.count > 64 {
      draftPreflightLastKnownResults.removeValue(
        forKey: draftPreflightLastKnownOrder.removeFirst())
    }
  }

  func pruneDraftPreflightLastKnownResults(keeping draftIDs: Set<UUID>) {
    guard draftPreflightLastKnownResults.keys.contains(where: { !draftIDs.contains($0) })
    else { return }
    draftPreflightLastKnownOrder.removeAll { !draftIDs.contains($0) }
    draftPreflightLastKnownResults = draftPreflightLastKnownResults.filter {
      draftIDs.contains($0.key)
    }
  }

  func invalidateDraftPreflightInputs() {
    draftPreflightDraftInputGeneration &+= 1
    clearDraftPreflightState()
  }

  func clearDraftPreflightState() {
    for operation in draftPreflightRefreshTasks.values { operation.cancel() }
    draftPreflightRefreshTasks.removeAll(keepingCapacity: true)
    draftPreflightSnapshots.removeAll(keepingCapacity: true)
    draftPreflightGenerations.removeAll(keepingCapacity: true)
    draftPreflightAccessOrder.removeAll(keepingCapacity: true)
    scheduleDraftPublishStatusNotification()
  }

  /// Suppresses only the synchronous document publication of derived counts.
  /// Restoring the prior value also preserves nested subscriber publications.
  func withDerivedWordCountPublication(_ publication: () -> Void) {
    let previous = isPublishingDerivedWordCount
    isPublishingDerivedWordCount = true
    defer { isPublishingDerivedWordCount = previous }
    publication()
  }

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
