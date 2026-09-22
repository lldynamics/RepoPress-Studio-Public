import Combine
import Foundation
import PublishingDomainContracts

public enum AssetResourceOperationPresentation: Equatable, Sendable {
  case loading(detail: String)
  case success(detail: String)
  case partialSuccess(detail: String)
  case failure(reason: String)
}

public struct AssetResourceOperationTaskDescriptor: Equatable, Identifiable, Sendable {
  public let profileID: UUID
  public let title: String
  public let presentation: AssetResourceOperationPresentation

  public var id: UUID { profileID }
}

private struct AssetResourceOperationState {
  var operationID: UUID?
  var title: String?
  var presentation: AssetResourceOperationPresentation?
  var completionRevision: UInt64 = 0
}

@MainActor
public final class WorkbenchImageWorkbenchFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  @Published private var assetResourceOperationStatesByProfileID:
    [UUID: AssetResourceOperationState] = [:]
  @Published public private(set) var assetResourceManagerNavigationRequest:
    AssetResourceManagerNavigationRequest?

  init(store: WorkbenchStore) {
    self.store = store
    // Keep image state local to the image fields this facade exposes.  A
    // publishing-store-wide bridge made every unrelated draft, release and
    // repository mutation redraw image controls.
    observeValue(store.publishingStore.$imageWorkbenchReport)
    observeValue(store.publishingStore.$imageActionMessage)
    observeValue(store.publishingStore.$imageInspectorFocusRequest)
    observeValue(store.$imageWorkbenchInputRevision)
    observeValue(store.aiWorkspaceStore.$aiTokenAvailability)
    observeValue(store.aiWorkspaceStore.$aiImageTextSuggestionDraftID)
    observeValue(store.aiWorkspaceStore.$aiImageTextSuggestions)
    observeValue(store.aiStore.$aiImageTextSuggestionRunningDraftIDs)
    observeValue(store.imageStore.$isImageBatchProcessing)
    observeValue(store.imageStore.$imageBatchProgress)
    observeValue(store.imageStore.$isSiteSummaryLoading)
    observeValue(store.imageStore.$siteSummaryErrorMessage)
  }

  public var report: ImageWorkbenchReport? {
    store.imageWorkbenchReport
  }

  public var actionMessage: String? {
    store.imageActionMessage
  }

  public var imageInspectorFocusRequest: ImageInspectorFocusRequest? {
    store.imageInspectorFocusRequest
  }

  public var suggestions: [AIPublishingImageTextSuggestion] {
    store.aiImageTextSuggestions
  }

  public var suggestionDraftID: UUID? {
    store.aiImageTextSuggestionDraftID
  }

  public var isGeneratingSuggestions: Bool {
    guard let draftID = store.selectedDraftID else { return false }
    return store.isAIImageTextRunning(for: draftID)
  }

  public var aiTokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var isProcessingBatch: Bool {
    store.imageStore.isImageBatchProcessing
  }

  public var batchProgress: ImageBatchProgress? {
    store.imageStore.imageBatchProgress
  }

  public var isSiteSummaryLoading: Bool {
    store.imageStore.isSiteSummaryLoading
  }

  public var siteSummaryErrorMessage: String? {
    store.imageStore.siteSummaryErrorMessage
  }

  /// Registers a file-mutating resource operation for one profile. Keeping this
  /// token on the store-owned facade prevents a view recreation from losing the
  /// in-flight lock while the underlying file operation is still running.
  public func beginAssetResourceOperation(
    for profileID: UUID,
    operationTitle: String = "资源处理",
    loadingDetail: String
  ) -> UUID? {
    var state =
      assetResourceOperationStatesByProfileID[profileID]
      ?? AssetResourceOperationState()
    guard state.operationID == nil else {
      return nil
    }
    let operationID = UUID()
    state.operationID = operationID
    state.title = operationTitle
    state.presentation = .loading(detail: loadingDetail)
    assetResourceOperationStatesByProfileID[profileID] = state
    return operationID
  }

  public func hasActiveAssetResourceOperation(for profileID: UUID) -> Bool {
    assetResourceOperationStatesByProfileID[profileID]?.operationID != nil
  }

  public func isCurrentAssetResourceOperation(
    _ operationID: UUID,
    for profileID: UUID
  ) -> Bool {
    assetResourceOperationStatesByProfileID[profileID]?.operationID == operationID
  }

  public func assetResourceOperationCompletionRevision(for profileID: UUID) -> UInt64 {
    assetResourceOperationStatesByProfileID[profileID]?.completionRevision ?? 0
  }

  public func assetResourceOperationPresentation(
    for profileID: UUID
  ) -> AssetResourceOperationPresentation? {
    assetResourceOperationStatesByProfileID[profileID]?.presentation
  }

  public func assetResourceOperationTitle(for profileID: UUID) -> String? {
    assetResourceOperationStatesByProfileID[profileID]?.title
  }

  public var assetResourceOperationTaskDescriptors: [AssetResourceOperationTaskDescriptor] {
    assetResourceOperationStatesByProfileID.compactMap { profileID, state in
      guard let title = state.title, let presentation = state.presentation else { return nil }
      return AssetResourceOperationTaskDescriptor(
        profileID: profileID,
        title: title,
        presentation: presentation
      )
    }
    .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
  }

  public func requestAssetResourceManagerNavigation(for profileID: UUID, windowID: UUID? = nil) {
    assetResourceManagerNavigationRequest = AssetResourceManagerNavigationRequest(
      profileID: profileID, windowID: windowID
    )
  }

  public func consumeAssetResourceManagerNavigationRequest(
    _ request: AssetResourceManagerNavigationRequest,
    from windowID: UUID? = nil
  ) {
    guard assetResourceManagerNavigationRequest == request, request.windowID == windowID
    else { return }
    assetResourceManagerNavigationRequest = nil
  }

  public func finishAssetResourceOperation(
    _ operationID: UUID,
    for profileID: UUID,
    presentation: AssetResourceOperationPresentation?
  ) {
    guard var state = assetResourceOperationStatesByProfileID[profileID],
      state.operationID == operationID
    else {
      return
    }
    state.operationID = nil
    state.presentation = presentation
    state.completionRevision &+= 1
    assetResourceOperationStatesByProfileID[profileID] = state
  }

  public func setActionMessage(_ message: String?) {
    store.setImageActionMessage(message)
  }

  public func refreshReport() {
    store.refreshImageWorkbenchReport()
  }

  public func report(for draft: ArticleDraft) -> ImageWorkbenchReport {
    store.imageWorkbenchReport(for: draft)
  }

  public func imageTextTargetCount(for draft: ArticleDraft, report: ImageWorkbenchReport?) -> Int {
    store.imageTextTargetCount(for: draft, report: report)
  }

  public func fillMissingMetadataForVisibleDrafts() {
    store.fillMissingImageMetadataForVisibleDrafts()
  }

  public func fillMissingMetadataForVisibleDrafts(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    store.fillMissingImageMetadataForVisibleDrafts(
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func optimizeSelectedDraftJPEGImages() {
    store.optimizeSelectedDraftJPEGImages()
  }

  public func sanitizeSelectedDraftImagePrivacy() {
    store.sanitizeSelectedDraftImagePrivacy()
  }

  public func sanitizeVisibleDraftImagePrivacy() {
    store.sanitizeVisibleDraftImagePrivacy()
  }

  public func sanitizeVisibleDraftImagePrivacy(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    store.sanitizeVisibleDraftImagePrivacy(
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func optimizeVisibleDraftJPEGImages() {
    store.optimizeVisibleDraftJPEGImages()
  }

  public func optimizeVisibleDraftJPEGImages(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    store.optimizeVisibleDraftJPEGImages(
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func convertSelectedDraftImagesToWebP() {
    store.convertSelectedDraftImagesToWebP()
  }

  public func convertVisibleDraftImagesToWebP() {
    store.convertVisibleDraftImagesToWebP()
  }

  public func convertVisibleDraftImagesToWebP(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    store.convertVisibleDraftImagesToWebP(
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func optimizeSelectedDraftSVGImages() {
    store.optimizeSelectedDraftSVGImages()
  }

  public func optimizeVisibleDraftSVGImages() {
    store.optimizeVisibleDraftSVGImages()
  }

  public func optimizeVisibleDraftSVGImages(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    store.optimizeVisibleDraftSVGImages(
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func resizeSelectedDraftLargeImages() {
    store.resizeSelectedDraftLargeImages()
  }

  public func resizeVisibleDraftLargeImages() {
    store.resizeVisibleDraftLargeImages()
  }

  public func resizeVisibleDraftLargeImages(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    store.resizeVisibleDraftLargeImages(
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func cancelBatchProcessing() {
    store.imageStore.cancelImageBatchProcessing()
  }

  public func cropSelectedDraftCoverImageForSocialPreview() {
    store.cropSelectedDraftCoverImageForSocialPreview()
  }

  public func attachRepositoryImageToSelectedDraft(repositoryPath: String) {
    store.attachRepositoryImageToSelectedDraft(repositoryPath: repositoryPath)
  }

  public func attachRepositoryImage(repositoryPath: String, toDraftID draftID: UUID) {
    store.attachRepositoryImage(repositoryPath: repositoryPath, toDraftID: draftID)
  }

  private func observeValue<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
