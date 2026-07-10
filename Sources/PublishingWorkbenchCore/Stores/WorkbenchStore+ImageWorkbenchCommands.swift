import Foundation

extension WorkbenchStore {
  public func refreshImageWorkbenchReport() {
    imageStore.refreshImageWorkbenchReport()
    invalidateDraftTaskQueueStateCache()
  }

  public func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    imageStore.imageWorkbenchReport(for: draft)
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
