import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ImageWorkbenchPresentationTests: XCTestCase {
  func testBatchActionsExposeFiveStableUniqueIdentifiers() {
    let actions = ImageWorkbenchBatchAction.allActions

    XCTAssertEqual(
      actions.map(\.id),
      [
        "fill-metadata",
        "optimize-jpeg",
        "convert-webp",
        "optimize-svg",
        "resize-large-images",
      ]
    )
    XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
    XCTAssertEqual(
      actions.map(\.accessibilityIdentifier),
      [
        "image-action-fill-metadata",
        "image-action-optimize-jpeg",
        "image-action-convert-webp",
        "image-action-optimize-svg",
        "image-action-resize-large-images",
      ]
    )
    XCTAssertEqual(Set(actions.map(\.accessibilityIdentifier)).count, actions.count)
  }

  func testBatchActionTargetCountsMatchVisibleEligibleImages() {
    let metadataAndJPEG = makeItem(
      filename: "hero.jpg",
      missingAltText: true,
      missingCaption: true,
      canOptimizeJPEG: true,
      canConvertToWebP: true,
      canResizeImage: true
    )
    let metadataAndSVG = makeItem(
      filename: "diagram.svg",
      missingCaption: true,
      canOptimizeSVG: true
    )
    let unaffected = makeItem(filename: "ready.png")
    let draftSummary = makeDraftSummary(
      issueCount: 2,
      errorCount: 0,
      warningCount: 2,
      items: [metadataAndJPEG, metadataAndSVG, unaffected]
    )
    let summary = ImageWorkbenchSiteSummary(
      draftCount: 1,
      imageCount: 3,
      totalByteSize: 3_000,
      issueCount: 2,
      errorCount: 0,
      warningCount: 2,
      missingAltTextCount: 1,
      missingCaptionCount: 2,
      missingSourceCount: 0,
      optimizableJPEGCount: 1,
      webPConvertibleCount: 1,
      optimizableSVGCount: 1,
      resizableImageCount: 1,
      draftSummaries: [draftSummary]
    )
    let counts = Dictionary(
      uniqueKeysWithValues: ImageWorkbenchBatchAction.allActions.map {
        ($0.id, $0.targetCount(in: summary))
      }
    )

    XCTAssertEqual(counts["fill-metadata"], 2)
    XCTAssertEqual(counts["optimize-jpeg"], 1)
    XCTAssertEqual(counts["convert-webp"], 1)
    XCTAssertEqual(counts["optimize-svg"], 1)
    XCTAssertEqual(counts["resize-large-images"], 1)
  }

  func testRepositoryImageFiltersSeparateRegisteredAndUnregisteredAssets() {
    let referenced = RepositoryImageAsset(
      repositoryPath: "static/images/used.png",
      absoluteFilePath: "/tmp/used.png",
      filename: "used.png",
      fileExtension: "png",
      byteSize: 100,
      modifiedAt: nil,
      references: [
        RepositoryImageReference(draftID: UUID(), draftTitle: "Using article", isCover: false),
      ]
    )
    let unreferenced = RepositoryImageAsset(
      repositoryPath: "static/images/free.png",
      absoluteFilePath: "/tmp/free.png",
      filename: "free.png",
      fileExtension: "png",
      byteSize: 200,
      modifiedAt: nil,
      references: []
    )

    XCTAssertTrue(RepositoryImageFilter.all.includes(referenced))
    XCTAssertTrue(RepositoryImageFilter.all.includes(unreferenced))
    XCTAssertTrue(RepositoryImageFilter.registered.includes(referenced))
    XCTAssertFalse(RepositoryImageFilter.registered.includes(unreferenced))
    XCTAssertFalse(RepositoryImageFilter.unregistered.includes(referenced))
    XCTAssertTrue(RepositoryImageFilter.unregistered.includes(unreferenced))
  }

  func testIssueArticleFiltersUseErrorAndWarningCounts() {
    let error = makeDraftSummary(issueCount: 1, errorCount: 1, warningCount: 0)
    let warning = makeDraftSummary(issueCount: 1, errorCount: 0, warningCount: 1)
    let clean = makeDraftSummary(issueCount: 0, errorCount: 0, warningCount: 0)

    XCTAssertTrue(ImageIssueArticleFilter.all.includes(error))
    XCTAssertTrue(ImageIssueArticleFilter.all.includes(warning))
    XCTAssertFalse(ImageIssueArticleFilter.all.includes(clean))
    XCTAssertTrue(ImageIssueArticleFilter.errors.includes(error))
    XCTAssertFalse(ImageIssueArticleFilter.errors.includes(warning))
    XCTAssertTrue(ImageIssueArticleFilter.warnings.includes(warning))
    XCTAssertFalse(ImageIssueArticleFilter.warnings.includes(error))
  }

  func testBatchAffectedItemIdentityIncludesDraftAndAttachment() {
    let sharedAttachmentID = UUID()
    let firstDraftID = UUID()
    let secondDraftID = UUID()
    let item = ImageWorkbenchItem(
      attachmentID: sharedAttachmentID,
      originalFilename: "shared.jpg",
      relativePublishPath: "/images/shared.jpg",
      repositoryPath: "static/images/shared.jpg",
      sourceFilePath: "/tmp/shared.jpg",
      byteSize: 100,
      dimensions: nil,
      fileExists: true,
      isCover: false,
      isReferencedInMarkdown: true,
      missingAltText: true,
      missingCaption: false,
      canOptimizeJPEG: true
    )

    let first = ImageBatchAffectedItem(draftID: firstDraftID, draftTitle: "First", item: item)
    let second = ImageBatchAffectedItem(draftID: secondDraftID, draftTitle: "Second", item: item)

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(Set([first.id, second.id]).count, 2)
  }

  private func makeItem(
    filename: String,
    missingAltText: Bool = false,
    missingCaption: Bool = false,
    canOptimizeJPEG: Bool = false,
    canConvertToWebP: Bool = false,
    canOptimizeSVG: Bool = false,
    canResizeImage: Bool = false
  ) -> ImageWorkbenchItem {
    ImageWorkbenchItem(
      attachmentID: UUID(),
      originalFilename: filename,
      relativePublishPath: "/images/\(filename)",
      repositoryPath: "static/images/\(filename)",
      sourceFilePath: "/tmp/\(filename)",
      byteSize: 1_000,
      dimensions: ImageDimensions(width: 2_000, height: 1_200),
      fileExists: true,
      isCover: false,
      isReferencedInMarkdown: true,
      missingAltText: missingAltText,
      missingCaption: missingCaption,
      canOptimizeJPEG: canOptimizeJPEG,
      canConvertToWebP: canConvertToWebP,
      canOptimizeSVG: canOptimizeSVG,
      canResizeImage: canResizeImage
    )
  }

  private func makeDraftSummary(
    issueCount: Int,
    errorCount: Int,
    warningCount: Int,
    items: [ImageWorkbenchItem] = []
  ) -> ImageWorkbenchDraftSummary {
    ImageWorkbenchDraftSummary(
      draftID: UUID(),
      draftTitle: "Image article",
      imageCount: items.count,
      issueCount: issueCount,
      errorCount: errorCount,
      warningCount: warningCount,
      missingAltTextCount: items.filter(\.missingAltText).count,
      missingCaptionCount: items.filter(\.missingCaption).count,
      missingSourceCount: 0,
      optimizableJPEGCount: items.filter(\.canOptimizeJPEG).count,
      webPConvertibleCount: items.filter(\.canConvertToWebP).count,
      optimizableSVGCount: items.filter(\.canOptimizeSVG).count,
      resizableImageCount: items.filter(\.canResizeImage).count,
      items: items
    )
  }
}
