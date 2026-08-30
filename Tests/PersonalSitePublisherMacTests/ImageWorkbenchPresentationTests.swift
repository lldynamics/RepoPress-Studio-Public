import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ImageWorkbenchPresentationTests: XCTestCase {
  func testBatchActionsExposeSixStableUniqueIdentifiers() {
    let actions = ImageWorkbenchBatchAction.allActions

    XCTAssertEqual(
      actions.map(\.id),
      [
        "fill-metadata",
        "optimize-jpeg",
        "convert-webp",
        "optimize-svg",
        "resize-large-images",
        "remove-privacy-metadata",
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
        "image-action-remove-privacy-metadata",
      ]
    )
    XCTAssertEqual(Set(actions.map(\.accessibilityIdentifier)).count, actions.count)

    let privacyAction = ImageWorkbenchBatchAction.file(.removePrivacyMetadata)
    XCTAssertEqual(privacyAction.title, "清除隐私信息")
    XCTAssertEqual(privacyAction.id, "remove-privacy-metadata")
    XCTAssertTrue(privacyAction.shortDescription.contains("脱敏副本"))
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
      canOptimizeSVG: true,
      hasSensitiveMetadata: true
    )
    let sensitiveOnly = makeItem(filename: "private.jpg", hasSensitiveMetadata: true)
    let unaffected = makeItem(filename: "ready.png")
    let draftSummary = makeDraftSummary(
      issueCount: 2,
      errorCount: 0,
      warningCount: 2,
      items: [metadataAndJPEG, metadataAndSVG, sensitiveOnly, unaffected]
    )
    let summary = ImageWorkbenchSiteSummary(
      draftCount: 1,
      imageCount: 4,
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
    XCTAssertEqual(counts["remove-privacy-metadata"], 2)
  }

  func testPrivacyMetadataActionFiltersOnlySensitiveImages() {
    let sensitive = makeItem(filename: "with-location.jpg", hasSensitiveMetadata: true)
    let clean = makeItem(filename: "clean.jpg")

    XCTAssertTrue(ImageWorkbenchBatchAction.file(.removePrivacyMetadata).includes(sensitive))
    XCTAssertFalse(ImageWorkbenchBatchAction.file(.removePrivacyMetadata).includes(clean))
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
        RepositoryImageReference(draftID: UUID(), draftTitle: "Using article", isCover: false)
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

  func testRepositoryImageProjectionFiltersQueriesAndSortsDeterministically() {
    let sharedDate = Date(timeIntervalSince1970: 100)
    let assets = [
      makeRepositoryAsset(
        path: "static/hero/apple.png",
        filename: "apple.png",
        byteSize: 100,
        modifiedAt: sharedDate,
        isRegistered: true
      ),
      makeRepositoryAsset(
        path: "static/blog/banana.png",
        filename: "banana.png",
        byteSize: 100,
        modifiedAt: sharedDate,
        isRegistered: false
      ),
      makeRepositoryAsset(
        path: "static/hero/cherry.png",
        filename: "cherry.png",
        byteSize: 300,
        modifiedAt: nil,
        isRegistered: true
      ),
      makeRepositoryAsset(
        path: "static/archive/date.png",
        filename: "date.png",
        byteSize: 50,
        modifiedAt: Date(timeIntervalSince1970: 200),
        isRegistered: false
      ),
    ]

    func projectedPaths(
      query: String = "",
      filter: RepositoryImageFilter = .all,
      sortOrder: RepositoryImageSortOrder
    ) -> [String] {
      RepositoryImageBrowserView.project(
        assets,
        query: query,
        filter: filter,
        sortOrder: sortOrder
      ).map(\.repositoryPath)
    }

    XCTAssertEqual(
      projectedPaths(query: "hero", sortOrder: .nameAsc),
      ["static/hero/apple.png", "static/hero/cherry.png"]
    )
    XCTAssertEqual(
      projectedPaths(query: "BANANA", sortOrder: .nameAsc),
      ["static/blog/banana.png"]
    )
    XCTAssertEqual(
      projectedPaths(filter: .registered, sortOrder: .nameAsc),
      ["static/hero/apple.png", "static/hero/cherry.png"]
    )
    XCTAssertEqual(
      projectedPaths(filter: .unregistered, sortOrder: .nameAsc),
      ["static/blog/banana.png", "static/archive/date.png"]
    )

    let expectedPaths: [RepositoryImageSortOrder: [String]] = [
      .nameAsc: ["apple.png", "banana.png", "cherry.png", "date.png"],
      .nameDesc: ["date.png", "cherry.png", "banana.png", "apple.png"],
      .dateNewest: ["date.png", "apple.png", "banana.png", "cherry.png"],
      .dateOldest: ["cherry.png", "apple.png", "banana.png", "date.png"],
      .sizeLargest: ["cherry.png", "apple.png", "banana.png", "date.png"],
      .sizeSmallest: ["date.png", "apple.png", "banana.png", "cherry.png"],
      .unregisteredFirst: ["banana.png", "date.png", "apple.png", "cherry.png"],
      .registeredFirst: ["apple.png", "cherry.png", "banana.png", "date.png"],
    ]
    for sortOrder in RepositoryImageSortOrder.allCases {
      XCTAssertEqual(
        RepositoryImageBrowserView.project(
          assets,
          query: "",
          filter: .all,
          sortOrder: sortOrder
        ).map(\.filename),
        expectedPaths[sortOrder],
        "Unexpected projection for \(sortOrder)"
      )
    }
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
    canResizeImage: Bool = false,
    hasSensitiveMetadata: Bool = false
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
      canResizeImage: canResizeImage,
      privacyStatus: hasSensitiveMetadata ? .sensitive : .clean
    )
  }

  private func makeRepositoryAsset(
    path: String,
    filename: String,
    byteSize: Int64,
    modifiedAt: Date?,
    isRegistered: Bool
  ) -> RepositoryImageAsset {
    RepositoryImageAsset(
      repositoryPath: path,
      absoluteFilePath: "/tmp/\(filename)",
      filename: filename,
      fileExtension: "png",
      byteSize: byteSize,
      modifiedAt: modifiedAt,
      references: isRegistered
        ? [
          RepositoryImageReference(
            draftID: UUID(),
            draftTitle: "Referenced article",
            isCover: false
          )
        ]
        : []
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
