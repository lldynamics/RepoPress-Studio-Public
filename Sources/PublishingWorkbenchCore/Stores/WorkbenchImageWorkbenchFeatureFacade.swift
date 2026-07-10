import Foundation

@MainActor
public final class WorkbenchImageWorkbenchFeatureFacade {
  private unowned let store: WorkbenchStore

  init(store: WorkbenchStore) {
    self.store = store
  }

  public var report: ImageWorkbenchReport? {
    get { store.imageWorkbenchReport }
  }

  public var actionMessage: String? {
    get { store.imageActionMessage }
  }

  public var suggestions: [AIPublishingImageTextSuggestion] {
    get { store.aiImageTextSuggestions }
  }

  public var suggestionDraftID: UUID? {
    get { store.aiImageTextSuggestionDraftID }
  }

  public var isGeneratingSuggestions: Bool {
    get { store.isAIImageTextRunning }
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

  public func fillMissingMetadataForSelectedDraft() {
    store.fillMissingImageMetadataForSelectedDraft()
  }

  public func fillMissingMetadataForVisibleDrafts() {
    store.fillMissingImageMetadataForVisibleDrafts()
  }

  public func optimizeSelectedDraftJPEGImages() {
    store.optimizeSelectedDraftJPEGImages()
  }

  public func optimizeVisibleDraftJPEGImages() {
    store.optimizeVisibleDraftJPEGImages()
  }

  public func convertSelectedDraftImagesToWebP() {
    store.convertSelectedDraftImagesToWebP()
  }

  public func convertVisibleDraftImagesToWebP() {
    store.convertVisibleDraftImagesToWebP()
  }

  public func optimizeSelectedDraftSVGImages() {
    store.optimizeSelectedDraftSVGImages()
  }

  public func optimizeVisibleDraftSVGImages() {
    store.optimizeVisibleDraftSVGImages()
  }

  public func resizeSelectedDraftLargeImages() {
    store.resizeSelectedDraftLargeImages()
  }

  public func resizeVisibleDraftLargeImages() {
    store.resizeVisibleDraftLargeImages()
  }

  public func cropSelectedDraftCoverImageForSocialPreview() {
    store.cropSelectedDraftCoverImageForSocialPreview()
  }

  public func attachRepositoryImageToSelectedDraft(repositoryPath: String) {
    store.attachRepositoryImageToSelectedDraft(repositoryPath: repositoryPath)
  }

  public func prepareAISuggestions(for draft: ArticleDraft) {
    store.aiPrepareImageTextSuggestions(for: draft)
  }

  @discardableResult
  public func generateAISuggestions(draft: ArticleDraft) async -> [AIPublishingImageTextSuggestion] {
    await store.aiGenerateImageTextSuggestions(draft: draft)
  }

  public func applyAISuggestion(_ suggestion: AIPublishingImageTextSuggestion) {
    store.aiApplyImageTextSuggestion(suggestion)
  }

  public func applyAISuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    store.aiApplyImageTextSuggestions(suggestions)
  }

  public func clearAISuggestions() {
    store.aiClearImageTextSuggestions()
  }
}
