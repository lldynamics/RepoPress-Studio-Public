import Combine
import Foundation
import PublishingDomainContracts

public enum PublishActionMessageStatus: String, Hashable, Sendable {
  case information
  case inProgress
  case success
  case warning
  case failure
}

public struct PublishActionFeedback: Hashable, Sendable {
  public let message: String
  public let status: PublishActionMessageStatus

  public init(message: String, status: PublishActionMessageStatus) {
    self.message = message
    self.status = status
  }
}

public struct RecentlyDeletedProfile: Sendable {
  public let profile: SiteProfile
  public let drafts: [ArticleDraft]
  public let customMarkdownSnippets: [MarkdownSnippet]
  public let draftVersions: [DraftVersionSnapshot]
  public let recycledDrafts: [RecycledDraft]
  public let draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest]
  public let markdownEditorSessionStates: [UUID: MarkdownEditorSessionState]
  public let deletedAt: Date

  public var draftCount: Int { drafts.count }
}

extension PublishingStore {
  public func draft(for draftID: UUID) -> ArticleDraft? {
    documents.draft(for: draftID)
  }

  func repositoryAccessToken(for profile: SiteProfile) throws -> String? {
    try repositoryTokenStore.repositoryToken(for: profile)
  }

  func beginLocalRepositoryMutation(profile: SiteProfile) -> LocalRepositoryOperationContext? {
    guard localRepositoryMutationContext == nil,
      remoteRepositoryMutationContext == nil,
      remoteConflictResolutionOperationID == nil
    else { return nil }
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

  func beginRemoteRepositoryMutation(
    profile: SiteProfile,
    store: WorkbenchStore,
    conflictResolutionOperationID: UUID? = nil
  )
    -> RemoteRepositoryOperationContext?
  {
    guard remoteRepositoryMutationContext == nil,
      localRepositoryMutationContext == nil,
      (remoteConflictResolutionOperationID == nil
        || remoteConflictResolutionOperationID == conflictResolutionOperationID),
      !store.isLocalRepositoryBranchOperationRunning,
      !store.isRemoteRepositoryChecking
    else { return nil }
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

  func finishRemoteRepositoryMutation(
    _ context: RemoteRepositoryOperationContext, store: WorkbenchStore
  ) {
    guard remoteRepositoryMutationContext == context else { return }
    remoteRepositoryMutationContext = nil
    store.setRemoteRepositoryPublishing(false)
  }

  func remoteRepositoryOperationWasCancelled(_ error: Error) -> Bool {
    if Task.isCancelled || error is CancellationError {
      return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    let cocoaError = error as NSError
    return cocoaError.domain == NSURLErrorDomain && cocoaError.code == URLError.cancelled.rawValue
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
  let generalDraftLibraryService: GeneralDraftLibraryService
  let localSitePreviewService: LocalSitePreviewService
  let localSitePreviewProcessService: LocalSitePreviewProcessService
  let siteMaintenanceService: SiteMaintenanceService
  let draftLifecycleService: DraftLifecycleService
  let contentHealthReportService: ContentHealthReportService
  let aiFixQueueService: AIPublishingFixQueueService
  /// Durable article data belongs to the document domain, not publishing.
  public let documents: DocumentStore
  /// Per-document editing state remains process-local and narrowly observed.
  public let documentSession: DocumentSessionStore
  public let publishSession: PublishSessionStore
  private var childStateCancellables = Set<AnyCancellable>()
  #if DEBUG
    /// Signals that an asynchronous remote-SHA backfill has reached a terminal
    /// path, allowing stale-result tests to distinguish completion from the
    /// request's initial nil SHA.
    var remoteSHABackfillCompletionTestHook: ((UUID) -> Void)?
  #endif

  @Published public internal(set) var profiles: [SiteProfile]
  @Published public internal(set) var activeProfileID: UUID {
    didSet {
      guard activeProfileID != oldValue else { return }
      projectSelectedDraftPublishPreview()
    }
  }
  /// Compatibility forwarding for existing actions. Source state is held by
  /// `documents`; new document consumers should depend on that store directly.
  public internal(set) var drafts: [ArticleDraft] {
    get { documents.drafts }
    set { documents.drafts = newValue }
  }
  public internal(set) var customMarkdownSnippets: [MarkdownSnippet] {
    get { documents.customMarkdownSnippets }
    set { documents.customMarkdownSnippets = newValue }
  }
  public internal(set) var draftVersions: [DraftVersionSnapshot] {
    get { documents.draftVersions }
    set { documents.draftVersions = newValue }
  }
  public internal(set) var recycledDrafts: [RecycledDraft] {
    get { documents.recycledDrafts }
    set { documents.recycledDrafts = newValue }
  }
  public internal(set) var draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest]
  {
    get { documents.draftRepositoryCleanupRequests }
    set { documents.draftRepositoryCleanupRequests = newValue }
  }
  @Published public internal(set) var selectedSection: WorkspaceSection
  @Published public internal(set) var selectedDraftID: UUID? {
    didSet {
      guard selectedDraftID != oldValue else { return }
      projectSelectedDraftPublishPreview()
    }
  }
  @Published public internal(set) var draftListContentScope: DraftListContentScope
  @Published public internal(set) var draftNavigationHistory: DraftNavigationHistory
  @Published public internal(set) var imageWorkbenchReport: ImageWorkbenchReport?
  @Published public internal(set) var isInspectorPresented: Bool
  @Published public internal(set) var editorFocusRequest: EditorFocusRequest?
  @Published public internal(set) var imageInspectorFocusRequest: ImageInspectorFocusRequest?
  public internal(set) var markdownEditorSessionStates: [UUID: MarkdownEditorSessionState] {
    get { documentSession.markdownEditorSessionStates }
    set { documentSession.markdownEditorSessionStates = newValue }
  }
  public internal(set) var draftBodyEditorBuffers: [UUID: DraftBodyEditorBuffer] {
    get { documentSession.draftBodyEditorBuffers }
    set { documentSession.draftBodyEditorBuffers = newValue }
  }
  let draftBodyEditorBufferWillChange: PassthroughSubject<UUID, Never>
  /// The live editor selection is intentionally kept out of the broad
  /// PublishingStore observation graph. High-frequency caret changes belong to
  /// a draft-scoped observation facade, not to the whole workbench.
  public internal(set) var activeEditorSelection: ActiveEditorSelection? {
    get { documentSession.activeEditorSelection }
    set { documentSession.activeEditorSelection = newValue }
  }
  let activeEditorSelectionDidChange: PassthroughSubject<UUID, Never>
  /// Sent after a buffer has been committed to the in-memory projection. The
  /// existing `willChange` subject remains for broad editor facades that use
  /// its historical pre-mutation timing; this subject is the narrow, live
  /// projection boundary and is emitted even when those observers are muted.
  let draftBodyEditorBufferDidChange: PassthroughSubject<UUID, Never>
  @Published public internal(set) var automaticallyRefreshPreflightOnEdit: Bool
  @Published public internal(set) var lastSaveStatus: String
  public internal(set) var publishActionMessage: String? {
    get { publishActionFeedback?.message }
    set {
      publishActionFeedback = newValue.map {
        PublishActionFeedback(message: $0, status: .information)
      }
    }
  }
  @Published public internal(set) var imageActionMessage: String?
  @Published public internal(set) var maintenanceOperationRecords: [MaintenanceOperationRecord]
  @Published public internal(set) var latestGeneralDraftReusePlan: GeneralDraftReusePlan?
  @Published public internal(set) var recentlyDeletedProfile: RecentlyDeletedProfile?
  @Published var latestDraftOwnershipTransferUndoState: DraftOwnershipTransferUndoState? = nil

  func setDraftBodyEditorBuffer(
    _ buffer: DraftBodyEditorBuffer,
    for draftID: UUID,
    notifyObservers: Bool = true
  ) {
    documentSession.setDraftBodyEditorBuffer(
      buffer,
      for: draftID,
      notifyObservers: notifyObservers
    )
  }

  func removeDraftBodyEditorBuffer(for draftID: UUID) {
    documentSession.removeDraftBodyEditorBuffer(for: draftID)
  }

  init(
    profiles: [SiteProfile],
    activeProfileID: UUID,
    drafts: [ArticleDraft],
    customMarkdownSnippets: [MarkdownSnippet] = [],
    draftVersions: [DraftVersionSnapshot] = [],
    recycledDrafts: [RecycledDraft] = [],
    draftRepositoryCleanupRequests: [DraftRepositoryCleanupRequest] = [],
    releaseRecords: [ReleaseRecord],
    selectedSection: WorkspaceSection = .writing,
    selectedDraftID: UUID? = nil,
    draftListContentScope: DraftListContentScope = .currentSite,
    draftNavigationHistory: DraftNavigationHistory? = nil,
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
    imageWorkbenchReport: ImageWorkbenchReport? = nil,
    preflightIssues: [PreflightIssue] = [],
    isInspectorPresented: Bool = true,
    editorFocusRequest: EditorFocusRequest? = nil,
    imageInspectorFocusRequest: ImageInspectorFocusRequest? = nil,
    markdownEditorSessionStates: [UUID: MarkdownEditorSessionState] = [:],
    activeEditorSelection: ActiveEditorSelection? = nil,
    automaticallyRefreshPreflightOnEdit: Bool = true,
    lastSaveStatus: String = "尚未保存",
    publishActionMessage: String? = nil,
    imageActionMessage: String? = nil,
    maintenanceOperationRecords: [MaintenanceOperationRecord] = [],
    latestGeneralDraftReusePlan: GeneralDraftReusePlan? = nil,
    recentlyDeletedProfile: RecentlyDeletedProfile? = nil,
    preflightService: PreflightCheckService = PreflightCheckService(),
    publishPackageBuilder: PublishPackageBuilder = PublishPackageBuilder(),
    localPublishPreviewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    batchPublishPlanService: BatchPublishPlanService = BatchPublishPlanService(),
    remoteRepositoryPublishService: RemoteRepositoryPublishService =
      RemoteRepositoryPublishService(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.repository),
    localGitPublishService: LocalGitPublishService = LocalGitPublishService(),
    remoteReviewDraftBuilder: RemoteReviewDraftBuilder = RemoteReviewDraftBuilder(),
    batchPublishCommandBuilder: BatchPublishCommandBuilder = BatchPublishCommandBuilder(),
    remotePublishRiskService: RemotePublishRiskService = RemotePublishRiskService(),
    localContentImportService: LocalContentImportService = LocalContentImportService(),
    contentMigrationService: ContentMigrationService = ContentMigrationService(),
    generalDraftLibraryService: GeneralDraftLibraryService = GeneralDraftLibraryService(),
    localSitePreviewService: LocalSitePreviewService = LocalSitePreviewService(),
    localSitePreviewProcessService: LocalSitePreviewProcessService =
      LocalSitePreviewProcessService(),
    siteMaintenanceService: SiteMaintenanceService = SiteMaintenanceService(),
    draftLifecycleService: DraftLifecycleService = DraftLifecycleService(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService()
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
    self.generalDraftLibraryService = generalDraftLibraryService
    self.localSitePreviewService = localSitePreviewService
    self.localSitePreviewProcessService = localSitePreviewProcessService
    self.siteMaintenanceService = siteMaintenanceService
    self.draftLifecycleService = draftLifecycleService
    self.contentHealthReportService = ContentHealthReportService(
      preflightService: preflightService,
      imageWorkbenchService: imageWorkbenchService
    )
    self.aiFixQueueService = AIPublishingFixQueueService()
    self.publishSession = PublishSessionStore(
      releaseRecords: releaseRecords,
      publishPackage: publishPackage,
      localPublishPreview: localPublishPreview,
      localPublishReadiness: localPublishReadiness,
      remotePublishPreviewSnapshot: remotePublishPreviewSnapshot,
      batchPublishPlan: batchPublishPlan,
      batchRemotePublishPreviewSnapshot: batchRemotePublishPreviewSnapshot,
      localSitePreviewPlan: localSitePreviewPlan,
      localSitePreviewRuntimeStatus: localSitePreviewRuntimeStatus,
      remoteReviewDraft: remoteReviewDraft,
      batchRemoteReviewDraft: batchRemoteReviewDraft,
      preflightIssues: preflightIssues,
      publishActionFeedback: publishActionMessage.map {
        PublishActionFeedback(message: $0, status: .information)
      }
    )
    self.profiles = profiles
    self.activeProfileID = activeProfileID
    let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    let normalizedDrafts = drafts.map { draft in
      var normalized = draft
      if normalized.isGeneralDraft {
        normalized.detachFromRepository()
      } else if let profile = profilesByID[normalized.siteProfileID] {
        normalized.normalizeRepositoryBinding(for: profile)
      }
      return normalized
    }
    self.documents = DocumentStore(
      drafts: normalizedDrafts,
      customMarkdownSnippets: customMarkdownSnippets,
      draftVersions: draftVersions,
      recycledDrafts: recycledDrafts,
      draftRepositoryCleanupRequests: draftRepositoryCleanupRequests
    )
    self.documentSession = DocumentSessionStore(
      markdownEditorSessionStates: markdownEditorSessionStates,
      activeEditorSelection: activeEditorSelection
    )
    self.draftBodyEditorBufferWillChange = documentSession.draftBodyEditorBufferWillChange
    self.draftBodyEditorBufferDidChange = documentSession.draftBodyEditorBufferDidChange
    self.activeEditorSelectionDidChange = documentSession.activeEditorSelectionDidChange
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    self.draftListContentScope = draftListContentScope
    self.draftNavigationHistory =
      draftNavigationHistory
      ?? DraftNavigationHistory(currentDraftID: selectedDraftID)
    self.imageWorkbenchReport = imageWorkbenchReport
    self.isInspectorPresented = isInspectorPresented
    self.editorFocusRequest = editorFocusRequest
    self.imageInspectorFocusRequest = imageInspectorFocusRequest
    self.automaticallyRefreshPreflightOnEdit = automaticallyRefreshPreflightOnEdit
    self.lastSaveStatus = lastSaveStatus
    self.imageActionMessage = imageActionMessage
    self.maintenanceOperationRecords = maintenanceOperationRecords
    self.latestGeneralDraftReusePlan = latestGeneralDraftReusePlan
    self.recentlyDeletedProfile = recentlyDeletedProfile
    publishSession.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStateCancellables)
    documents.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &childStateCancellables)
    if let selectedDraftID,
      drafts.contains(where: { $0.id == selectedDraftID }),
      let profile = profiles.first(where: { $0.id == activeProfileID }),
      let publishPackage,
      publishPackage.draftID == selectedDraftID,
      let localPublishPreview,
      let localPublishReadiness,
      let remotePublishPreviewSnapshot,
      let remoteReviewDraft
    {
      draftPublishPreviewSnapshots[selectedDraftID] = DraftPublishPreviewSnapshot(
        context: DraftExecutionContext(
          draftID: selectedDraftID,
          profileID: profile.id,
          bodyRevision: draftBodyEditorBuffers[selectedDraftID]?.revision ?? 0
        ),
        publishPackage: publishPackage,
        localPublishPreview: localPublishPreview,
        localPublishReadiness: localPublishReadiness,
        remotePublishPreview: remotePublishPreviewSnapshot,
        remoteReviewDraft: remoteReviewDraft
      )
    }
    projectSelectedDraftPublishPreview()
  }

  func setPublishActionMessage(
    _ message: String?,
    status: PublishActionMessageStatus
  ) {
    publishActionFeedback = message.map {
      PublishActionFeedback(message: $0, status: status)
    }
  }

}
