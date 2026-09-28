import PublishingDomainContracts
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

final class RepositoryImageBrowserSessionTests: XCTestCase {
  func testFolderScopeIsSegmentSafeAndCanExcludeDescendants() {
    let images = [
      asset("static/images/a.png"), asset("static/images/nested/b.png"),
      asset("static/images-other/c.png"),
    ]
    let direct = RepositoryImageBrowserProjection.project(
      images, scope: .folder("static/images"), includesSubfolders: false, query: "", filter: .all,
      sortOrder: .nameAsc)
    let recursive = RepositoryImageBrowserProjection.project(
      images, scope: .folder("static/images"), includesSubfolders: true, query: "", filter: .all,
      sortOrder: .nameAsc)
    XCTAssertEqual(direct.map(\.filename), ["a.png"])
    XCTAssertEqual(recursive.map(\.filename), ["a.png", "b.png"])
  }

  func testRecentWindowAndSearchRegistrationFilterCompose() {
    let now = Date()
    let images = [
      asset("static/images/new.png", modifiedAt: now, registered: true),
      asset("static/images/old.png", modifiedAt: now.addingTimeInterval(-31 * 86400)),
      asset("static/images/unknown.png"),
    ]
    XCTAssertEqual(
      RepositoryImageBrowserProjection.project(
        images, scope: .recent, includesSubfolders: true, query: "", filter: .all,
        sortOrder: .nameAsc, now: now
      ).map(\.filename), ["new.png"])
    XCTAssertEqual(
      RepositoryImageBrowserProjection.project(
        images, scope: .all, includesSubfolders: true, query: "new", filter: .registered,
        sortOrder: .nameAsc
      ).map(\.filename), ["new.png"])
  }

  @MainActor
  func testRepeatedShiftArrowExtendsFromStableAnchor() {
    let session = RepositoryImageBrowserSession()
    session.visibleAssets = [asset("a.png"), asset("b.png"), asset("c.png")]
    session.select("a.png")
    session.moveSelection(by: 1, extending: true)
    session.moveSelection(by: 1, extending: true)
    XCTAssertEqual(session.selectedPaths, ["a.png", "b.png", "c.png"])
    session.moveSelection(by: -1, extending: true)
    XCTAssertEqual(session.selectedPaths, ["a.png", "b.png"])
  }

  @MainActor
  func testRefreshPreservesSelectionExpansionAndTargetButProfileChangeClearsThem() {
    let profile = SiteProfile.defaultProfile
    let targetDraftID = UUID()
    let session = RepositoryImageBrowserSession()
    session.prepare(for: profile, preferredDraftID: targetDraftID)
    session.selectedPaths = ["static/images/a.png", "static/images/b.png"]
    session.expandedPaths = ["static/images", "static/images/nested"]

    session.apply(inventory(profileID: profile.id, revisionID: UUID()))

    XCTAssertEqual(session.selectedPaths, ["static/images/a.png", "static/images/b.png"])
    XCTAssertTrue(session.expandedPaths.isSuperset(of: ["static/images", "static/images/nested"]))
    XCTAssertEqual(session.targetDraftID, targetDraftID)

    var changedProfile = profile
    changedProfile.id = UUID()
    session.prepare(for: changedProfile, preferredDraftID: nil)
    XCTAssertTrue(session.selectedPaths.isEmpty)
    XCTAssertTrue(session.expandedPaths.isEmpty)
    XCTAssertNil(session.targetDraftID)
  }

  private func asset(
    _ path: String,
    modifiedAt: Date? = nil,
    registered: Bool = false
  ) -> RepositoryImageAsset {
    RepositoryImageAsset(
      repositoryPath: path,
      absoluteFilePath: "/tmp/\(path)",
      filename: (path as NSString).lastPathComponent,
      fileExtension: "PNG",
      byteSize: 1,
      modifiedAt: modifiedAt,
      references: registered
        ? [RepositoryImageReference(draftID: UUID(), draftTitle: "Draft", isCover: false)] : []
    )
  }

  private func inventory(profileID: UUID, revisionID: UUID) -> RepositoryImageInventory {
    RepositoryImageInventory(
      revisionID: revisionID,
      profileID: profileID,
      repositoryRootPath: "/tmp/repository",
      assetRootPath: "static/images",
      assets: [asset("static/images/a.png"), asset("static/images/b.png")],
      directoryPaths: ["static/images", "static/images/nested"]
    )
  }
}

final class ImageBatchSelectionValidationTests: XCTestCase {
  @MainActor
  func testConfirmationFlushPreservesBufferedBodyAndRejectsChangedImageReferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("state.json")),
      safeMode: true)
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.attachments = makeDraft().attachments
    draft.bodyMarkdown = "![](/images/hero.png)"
    store.updateDraft(draft)
    let context = ImageBatchPreviewContext(store: store)
    let body = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody(
      body.bodyMarkdown + "\nNew paragraph", for: draft.id, baseRevision: body.revision)
    store.flushDraftBodyEditorBuffer(for: draft.id)
    XCTAssertTrue(context.matches(store))
    store.imageWorkbench.fillMissingMetadataForVisibleDrafts(includedAttachmentIDsByDraftID: [
      draft.id: [draft.attachments[0].id]
    ])
    store.flushDraftBodyEditorBuffer(for: draft.id)
    let updated = try XCTUnwrap(store.draft(for: draft.id))
    XCTAssertTrue(updated.bodyMarkdown.contains("New paragraph"))
    XCTAssertFalse(updated.bodyMarkdown.contains("![]"))

    let nextContext = ImageBatchPreviewContext(store: store)
    let next = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody(
      next.bodyMarkdown + "\n![](/images/new.png)", for: draft.id, baseRevision: next.revision)
    store.flushDraftBodyEditorBuffer(for: draft.id)
    XCTAssertFalse(nextContext.matches(store))
  }

  func testMatchingChildSelectionIsValid() {
    let draft = makeDraft()
    let item = makeItem(attachmentID: draft.attachments[0].id, path: "static/images/hero.png")
    let affected = [ImageBatchAffectedItem(draftID: draft.id, draftTitle: draft.title, item: item)]

    XCTAssertTrue(
      ImageBatchSelectionValidation.isValid(
        [draft.id: [draft.attachments[0].id]], affectedItems: affected, drafts: [draft]
      ))
  }

  func testUnknownAttachmentPathAndDraftAreRejected() {
    let draft = makeDraft()
    let attachmentID = draft.attachments[0].id
    let validItem = makeItem(attachmentID: attachmentID, path: "static/images/hero.png")
    let affected = [
      ImageBatchAffectedItem(draftID: draft.id, draftTitle: draft.title, item: validItem)
    ]

    XCTAssertFalse(
      ImageBatchSelectionValidation.isValid(
        [draft.id: [UUID()]], affectedItems: affected, drafts: [draft]
      ))

    let changedPath = makeItem(attachmentID: attachmentID, path: "static/images/moved.png")
    XCTAssertFalse(
      ImageBatchSelectionValidation.isValid(
        [draft.id: [attachmentID]],
        affectedItems: [
          ImageBatchAffectedItem(draftID: draft.id, draftTitle: draft.title, item: changedPath)
        ],
        drafts: [draft]
      ))

    XCTAssertFalse(
      ImageBatchSelectionValidation.isValid(
        [UUID(): [attachmentID]], affectedItems: affected, drafts: [draft]
      ))
  }

  private func makeDraft() -> ArticleDraft {
    ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id, title: "Hero", slug: "hero",
      attachments: [
        DraftAttachment(
          originalFilename: "hero.png", relativePublishPath: "/images/hero.png",
          repositoryPath: "static/images/hero.png"
        )
      ]
    )
  }

  private func makeItem(attachmentID: UUID, path: String) -> ImageWorkbenchItem {
    ImageWorkbenchItem(
      attachmentID: attachmentID, originalFilename: "hero.png",
      relativePublishPath: "/images/hero.png", repositoryPath: path,
      sourceFilePath: nil, byteSize: 1, dimensions: nil, fileExists: true,
      isCover: false, isReferencedInMarkdown: true, missingAltText: false,
      missingCaption: false, canOptimizeJPEG: false
    )
  }
}
