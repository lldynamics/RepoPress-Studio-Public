import Combine
import Foundation

@MainActor
public final class WorkbenchImageWorkbenchFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

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
    get { store.imageWorkbenchReport }
  }

  public var actionMessage: String? {
    get { store.imageActionMessage }
  }

  public var imageInspectorFocusRequest: ImageInspectorFocusRequest? {
    store.imageInspectorFocusRequest
  }

  public var suggestions: [AIPublishingImageTextSuggestion] {
    get { store.aiImageTextSuggestions }
  }

  public var suggestionDraftID: UUID? {
    get { store.aiImageTextSuggestionDraftID }
  }

  public var isGeneratingSuggestions: Bool {
    get {
      guard let draftID = store.selectedDraftID else { return false }
      return store.isAIImageTextRunning(for: draftID)
    }
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
