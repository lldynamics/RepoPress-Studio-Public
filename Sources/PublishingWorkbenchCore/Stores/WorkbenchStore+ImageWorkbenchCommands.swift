import Foundation

extension WorkbenchStore {
  public func refreshImageWorkbenchReport() {
    imageStore.refreshImageWorkbenchReport()
    invalidateDraftTaskQueueStateCache()
  }

  public func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    imageStore.imageWorkbenchReport(for: draft)
  }

  public func cachedImageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport? {
    imageStore.cachedImageWorkbenchReport(for: draft)
  }

  public func isImageWorkbenchReportLoading(for draft: ArticleDraft) -> Bool {
    imageStore.isImageWorkbenchReportLoading(for: draft)
  }

  public func refreshImageWorkbenchReportInBackground(
    for draft: ArticleDraft,
    force: Bool = false
  ) async {
    await imageStore.refreshImageWorkbenchReportInBackground(for: draft, force: force)
    invalidateDraftTaskQueueStateCache()
  }

  /// Starts an observation refresh without making selection/navigation wait on
  /// file-backed image inspection. The image store owns cancellation and stale
  /// result rejection for overlapping requests.
  func scheduleImageWorkbenchReportRefresh(
    for draft: ArticleDraft? = nil,
    force: Bool = false
  ) {
    guard let draft = draft ?? selectedDraft else { return }
    Task { @MainActor [weak self] in
      await self?.refreshImageWorkbenchReportInBackground(for: draft, force: force)
    }
  }

  /// Schedules both per-draft and site-wide file-backed image observation away
  /// from the caller's MainActor turn.
  public func scheduleImageWorkbenchCachesRefresh(
    for draft: ArticleDraft? = nil,
    force: Bool = false
  ) {
    guard let draft = draft ?? selectedDraft else {
      Task { @MainActor [weak self] in
        await self?.refreshImageWorkbenchSiteSummaryInBackground(force: force)
      }
      return
    }
    Task { @MainActor [weak self] in
      await self?.refreshImageWorkbenchCachesInBackground(for: draft, force: force)
    }
  }

  public var cachedImageWorkbenchSiteSummary: ImageWorkbenchSiteSummary? {
    imageStore.cachedImageWorkbenchSiteSummary()
  }

  public var isImageWorkbenchSiteSummaryLoading: Bool {
    imageStore.isSiteSummaryLoading
  }

  public func refreshImageWorkbenchSiteSummaryInBackground(force: Bool = false) async {
    await imageStore.refreshImageWorkbenchSiteSummaryInBackground(force: force)
    invalidateDraftTaskQueueStateCache()
  }

  public func refreshImageWorkbenchCachesInBackground(
    for draft: ArticleDraft,
    force: Bool = false
  ) async {
    await imageStore.refreshImageWorkbenchCachesInBackground(for: draft, force: force)
    invalidateDraftTaskQueueStateCache()
  }

  public func imageTextTargetCount(for draft: ArticleDraft, report: ImageWorkbenchReport?) -> Int {
    imageStore.imageTextTargetCount(for: draft, report: report)
  }

  public func fillMissingImageMetadataForSelectedDraft() {
    imageStore.fillMissingImageMetadataForSelectedDraft()
    invalidateDraftDerivedCaches()
  }

  public func fillMissingImageMetadataForVisibleDrafts() {
    imageStore.fillMissingImageMetadataForVisibleDrafts()
    invalidateDraftDerivedCaches()
  }

  public func optimizeSelectedDraftJPEGImages() {
    imageStore.optimizeSelectedDraftJPEGImages()
    invalidateDraftDerivedCaches()
  }

  public func optimizeVisibleDraftJPEGImages() {
    imageStore.optimizeVisibleDraftJPEGImages()
    invalidateDraftDerivedCaches()
  }

  public func convertSelectedDraftImagesToWebP() {
    imageStore.convertSelectedDraftImagesToWebP()
    invalidateDraftDerivedCaches()
  }

  public func convertVisibleDraftImagesToWebP() {
    imageStore.convertVisibleDraftImagesToWebP()
    invalidateDraftDerivedCaches()
  }

  public func optimizeSelectedDraftSVGImages() {
    imageStore.optimizeSelectedDraftSVGImages()
    invalidateDraftDerivedCaches()
  }

  public func optimizeVisibleDraftSVGImages() {
    imageStore.optimizeVisibleDraftSVGImages()
    invalidateDraftDerivedCaches()
  }

  public func resizeSelectedDraftLargeImages() {
    imageStore.resizeSelectedDraftLargeImages()
    invalidateDraftDerivedCaches()
  }

  public func resizeVisibleDraftLargeImages() {
    imageStore.resizeVisibleDraftLargeImages()
    invalidateDraftDerivedCaches()
  }

  public func cropSelectedDraftCoverImageForSocialPreview() {
    imageStore.cropSelectedDraftCoverImageForSocialPreview()
    invalidateDraftDerivedCaches()
  }

  public func setSelectedDraftCoverAttachment(_ attachmentID: UUID?) {
    imageStore.setSelectedDraftCoverAttachment(attachmentID)
    invalidateDraftDerivedCaches()
  }

  public func attachRepositoryImageToSelectedDraft(repositoryPath: String) {
    imageStore.attachRepositoryImageToSelectedDraft(repositoryPath: repositoryPath)
    invalidateDraftDerivedCaches()
  }

}
