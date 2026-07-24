import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreImageBatchTests: XCTestCase {
  func testAIChatImageAttachmentsLoadsSelectedDraftImages() async throws {
    let directory = try temporaryDirectory()
    let imageURL = directory.appendingPathComponent("cover.png")
    let imageData = Data([137, 80, 78, 71, 1, 2, 3])
    try imageData.write(to: imageURL)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png",
      byteSize: Int64(imageData.count),
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: store.activeProfile.id,
      title: "AI Image Context",
      slug: "ai-image-context",
      bodyMarkdown: "![cover](/images/cover.png)",
      attachments: [attachment]
    )

    let images = await store.aiChatImageAttachments(for: draft, attachmentIDs: [attachment.id])

    XCTAssertEqual(images.count, 1)
    XCTAssertEqual(images[0].filename, "cover.png")
    XCTAssertEqual(images[0].mimeType, "image/png")
    XCTAssertEqual(images[0].data, imageData)
  }

  func testAIChatImageAttachmentsUsesMobileEightMegabyteLimit() async throws {
    let directory = try temporaryDirectory()
    let imageURL = directory.appendingPathComponent("mobile-limit.png")
    let imageData = Data(repeating: 7, count: 5 * 1_024 * 1_024)
    try imageData.write(to: imageURL)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let attachment = DraftAttachment(
      originalFilename: "mobile-limit.png",
      relativePublishPath: "/images/mobile-limit.png",
      repositoryPath: "static/images/mobile-limit.png",
      byteSize: Int64(imageData.count),
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: store.activeProfile.id,
      title: "Mobile Limit",
      slug: "mobile-limit",
      attachments: [attachment]
    )

    let images = await store.aiChatImageAttachments(for: draft, attachmentIDs: [attachment.id])

    XCTAssertEqual(images.count, 1)
    XCTAssertEqual(images[0].data.count, 5 * 1_024 * 1_024)
    XCTAssertNil(store.aiChatMessage)
  }

  func testAIChatImageAttachmentsSkipsImagesAboveMobileEightMegabyteLimit() async throws {
    let directory = try temporaryDirectory()
    let imageURL = directory.appendingPathComponent("too-large.png")
    let imageData = Data(
      repeating: 9,
      count: AIPublishingChatImageAttachmentPresentation.maxAttachmentBytes + 1
    )
    try imageData.write(to: imageURL)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let attachment = DraftAttachment(
      originalFilename: "too-large.png",
      relativePublishPath: "/images/too-large.png",
      repositoryPath: "static/images/too-large.png",
      byteSize: 1,
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: store.activeProfile.id,
      title: "Too Large",
      slug: "too-large",
      attachments: [attachment]
    )

    let images = await store.aiChatImageAttachments(for: draft, attachmentIDs: [attachment.id])

    XCTAssertTrue(images.isEmpty)
    XCTAssertEqual(
      store.aiChatMessage,
      "已跳过 1 个无法读取、格式不支持或超过 \(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()) 的图片附件。"
    )
  }

  func testAIChatImageAttachmentsSkipsUnsupportedImageFormat() async throws {
    let directory = try temporaryDirectory()
    let imageURL = directory.appendingPathComponent("unsupported.heic")
    try Data([1, 2, 3, 4]).write(to: imageURL)
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let attachment = DraftAttachment(
      originalFilename: "unsupported.heic",
      relativePublishPath: "/images/unsupported.heic",
      repositoryPath: "static/images/unsupported.heic",
      byteSize: 4,
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "Unsupported AI Image",
      slug: "unsupported-ai-image",
      attachments: [attachment]
    )

    let images = await store.aiChatImageAttachments(for: draft, attachmentIDs: [attachment.id])

    XCTAssertTrue(images.isEmpty)
    XCTAssertTrue(store.aiChatMessage?.contains("格式不支持") == true)
  }

  func testAttachRepositoryImageToSelectedDraftKeepsRepositoryPathAndSourceFile() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images/2026", isDirectory: true),
      withIntermediateDirectories: true
    )
    let imageURL = rootURL.appendingPathComponent("static/images/2026/hero-image.jpg")
    try Data([1, 2, 3, 4]).write(to: imageURL)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.assetRoot = "static"
    profile.publicImagePathPattern = "/images/{year}/{filename}"
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: profile.id,
      title: "Image Draft",
      slug: "image-draft",
      bodyMarkdown: "Body"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.attachRepositoryImageToSelectedDraft(repositoryPath: "static/images/2026/hero-image.jpg")

    var updatedDraft = try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    let attachment = try XCTUnwrap(updatedDraft.attachments.first)
    XCTAssertEqual(updatedDraft.attachments.count, 1)
    XCTAssertEqual(attachment.originalFilename, "hero-image.jpg")
    XCTAssertEqual(attachment.relativePublishPath, "/images/2026/hero-image.jpg")
    XCTAssertEqual(attachment.repositoryPath, "static/images/2026/hero-image.jpg")
    XCTAssertEqual(attachment.altText, "hero image")
    XCTAssertEqual(attachment.byteSize, 4)
    let sourceFilePath = try XCTUnwrap(attachment.sourceFilePath)
    XCTAssertEqual(
      URL(fileURLWithPath: sourceFilePath).resolvingSymlinksInPath().path,
      imageURL.resolvingSymlinksInPath().path
    )
    XCTAssertEqual(store.selectedSection, .images)
    XCTAssertEqual(store.imageActionMessage, "已把 static/images/2026/hero-image.jpg 加入目标文章图片列表。")

    store.attachRepositoryImageToSelectedDraft(repositoryPath: "static/images/2026/hero-image.jpg")

    updatedDraft = try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    XCTAssertEqual(updatedDraft.attachments.count, 1)
    XCTAssertEqual(store.imageActionMessage, "static/images/2026/hero-image.jpg 已在目标文章图片列表中。")
  }

  func testAttachRepositoryImageRejectsUnsafeOrMissingFilesWithoutMutatingDraft() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([1, 2, 3]).write(to: rootURL.appendingPathComponent("outside.jpg"))

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.assetRoot = "static"
    store.updateActiveProfile(profile)
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: profile.id,
      title: "Protected Draft",
      slug: "protected-draft"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.attachRepositoryImageToSelectedDraft(repositoryPath: "../outside.jpg")
    XCTAssertEqual(store.drafts.first?.attachments, [])
    XCTAssertEqual(store.imageActionMessage, "仓库图片路径无效。")

    store.attachRepositoryImageToSelectedDraft(repositoryPath: "static/images/missing.jpg")
    XCTAssertEqual(store.drafts.first?.attachments, [])
    XCTAssertEqual(
      store.imageActionMessage,
      "图片文件不存在或无法读取：static/images/missing.jpg"
    )
  }

  func testAttachRepositoryImageUsesExplicitCurrentSiteTargetInsteadOfGeneralSelection() throws {
    let rootURL = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([1, 2, 3, 4]).write(
      to: rootURL.appendingPathComponent("static/images/library.png")
    )

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.assetRoot = "static"
    store.updateActiveProfile(profile)
    let siteDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: profile.id,
      title: "Site Target",
      slug: "site-target"
    )
    let generalDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: profile.id,
      scope: .general,
      title: "General Selection",
      slug: "general-selection"
    )
    store.setDrafts([siteDraft, generalDraft])
    store.setDraftListContentScope(.general)
    store.setSelectedDraftID(generalDraft.id)

    store.attachRepositoryImage(
      repositoryPath: "static/images/library.png",
      toDraftID: siteDraft.id
    )

    XCTAssertEqual(store.drafts.first(where: { $0.id == siteDraft.id })?.attachments.count, 1)
    XCTAssertEqual(store.drafts.first(where: { $0.id == generalDraft.id })?.attachments.count, 0)

    store.attachRepositoryImage(
      repositoryPath: "static/images/library.png",
      toDraftID: generalDraft.id
    )
    XCTAssertEqual(store.drafts.first(where: { $0.id == generalDraft.id })?.attachments.count, 0)
    XCTAssertEqual(store.imageActionMessage, "请选择当前站点中的目标文章。")
  }

  func testBatchFillImageMetadataUpdatesOnlyVisibleProfileDrafts() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let activeProfile = store.activeProfile
    var otherProfile = SiteProfile.defaultProfile
    otherProfile.id = UUID()
    otherProfile.name = "Other"
    store.setProfiles(store.profiles + [otherProfile])

    let firstAttachment = DraftAttachment(
      originalFilename: "hero-image.jpg",
      relativePublishPath: "/images/2026/hero-image.jpg",
      repositoryPath: "static/images/2026/hero-image.jpg",
      altText: "",
      caption: ""
    )
    let secondAttachment = DraftAttachment(
      originalFilename: "detail-image.jpg",
      relativePublishPath: "/images/2026/detail-image.jpg",
      repositoryPath: "static/images/2026/detail-image.jpg",
      altText: "",
      caption: ""
    )
    let otherAttachment = DraftAttachment(
      originalFilename: "other-image.jpg",
      relativePublishPath: "/images/2026/other-image.jpg",
      repositoryPath: "static/images/2026/other-image.jpg",
      altText: "",
      caption: ""
    )

    let firstDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: activeProfile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: "![](/images/2026/hero-image.jpg)",
      attachments: [firstAttachment]
    )
    let secondDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: activeProfile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: "![](/images/2026/detail-image.jpg)",
      attachments: [secondAttachment]
    )
    let otherDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: otherProfile.id,
      title: "Other",
      slug: "other",
      bodyMarkdown: "![](/images/2026/other-image.jpg)",
      attachments: [otherAttachment]
    )
    store.setDrafts([firstDraft, secondDraft, otherDraft])
    store.setSelectedDraftID(firstDraft.id)

    store.fillMissingImageMetadataForVisibleDrafts()

    let updatedFirst = try XCTUnwrap(store.drafts.first { $0.id == firstDraft.id })
    let updatedSecond = try XCTUnwrap(store.drafts.first { $0.id == secondDraft.id })
    let untouchedOther = try XCTUnwrap(store.drafts.first { $0.id == otherDraft.id })

    XCTAssertEqual(updatedFirst.attachments.first?.altText, "hero image")
    XCTAssertEqual(updatedFirst.attachments.first?.caption, "hero image")
    XCTAssertTrue(updatedFirst.bodyMarkdown.contains("![hero image](/images/2026/hero-image.jpg)"))
    XCTAssertEqual(updatedSecond.attachments.first?.altText, "detail image")
    XCTAssertEqual(updatedSecond.attachments.first?.caption, "detail image")
    XCTAssertEqual(untouchedOther.attachments.first?.altText, "")
    XCTAssertEqual(untouchedOther.attachments.first?.caption, "")
    XCTAssertTrue(store.imageActionMessage?.contains("已批量补全 2 个 alt") ?? false)
  }

  func testBatchOptimizeJPEGUpdatesOnlyVisibleProfileDrafts() async throws {
    let directory = try temporaryDirectory()
    let firstURL = directory.appendingPathComponent("first.jpg")
    let otherURL = directory.appendingPathComponent("other.jpg")
    try writeTestImage(at: firstURL, width: 360, height: 360, quality: 1.0)
    try writeTestImage(at: otherURL, width: 360, height: 360, quality: 1.0)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let activeProfile = store.activeProfile
    var otherProfile = SiteProfile.defaultProfile
    otherProfile.id = UUID()
    otherProfile.name = "Other"
    store.setProfiles(store.profiles + [otherProfile])

    let firstAttachment = DraftAttachment(
      originalFilename: "first.jpg",
      relativePublishPath: "/images/2026/first.jpg",
      repositoryPath: "static/images/2026/first.jpg",
      byteSize: Int64((try Data(contentsOf: firstURL)).count),
      sourceFilePath: firstURL.path
    )
    let otherAttachment = DraftAttachment(
      originalFilename: "other.jpg",
      relativePublishPath: "/images/2026/other.jpg",
      repositoryPath: "static/images/2026/other.jpg",
      byteSize: Int64((try Data(contentsOf: otherURL)).count),
      sourceFilePath: otherURL.path
    )
    let firstDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: activeProfile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: "![First](/images/2026/first.jpg)",
      attachments: [firstAttachment]
    )
    let otherDraft = ArticleDraft(
      id: UUID(),
      siteProfileID: otherProfile.id,
      title: "Other",
      slug: "other",
      bodyMarkdown: "![Other](/images/2026/other.jpg)",
      attachments: [otherAttachment]
    )
    store.setDrafts([firstDraft, otherDraft])
    store.setSelectedDraftID(firstDraft.id)

    store.optimizeVisibleDraftJPEGImages()

    XCTAssertTrue(store.imageWorkbench.isProcessingBatch)
    for _ in 0..<100 where store.imageWorkbench.isProcessingBatch {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(store.imageWorkbench.isProcessingBatch)

    let updatedFirst = try XCTUnwrap(store.drafts.first { $0.id == firstDraft.id })
    let untouchedOther = try XCTUnwrap(store.drafts.first { $0.id == otherDraft.id })

    XCTAssertNotEqual(updatedFirst.attachments.first?.sourceFilePath, firstURL.path)
    XCTAssertEqual(untouchedOther.attachments.first?.sourceFilePath, otherURL.path)
    XCTAssertTrue(store.imageActionMessage?.contains("已批量生成") ?? false)
  }

  func testCropCoverRunsThroughBackgroundBatchAndAppliesResult() async throws {
    let directory = try temporaryDirectory()
    let sourceURL = directory.appendingPathComponent("cover.jpg")
    try writeTestImage(at: sourceURL, width: 360, height: 360, quality: 1.0)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "static/images/2026/cover.jpg",
      byteSize: Int64((try Data(contentsOf: sourceURL)).count),
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      id: UUID(),
      siteProfileID: store.activeProfile.id,
      title: "Cover",
      slug: "cover",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "![Cover](/images/2026/cover.jpg)",
      attachments: [attachment]
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.cropSelectedDraftCoverImageForSocialPreview()

    XCTAssertTrue(store.imageWorkbench.isProcessingBatch)
    for _ in 0..<100 where store.imageWorkbench.isProcessingBatch {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(store.imageWorkbench.isProcessingBatch)

    let updatedDraft = try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    XCTAssertNotEqual(updatedDraft.attachments.first?.sourceFilePath, sourceURL.path)
    XCTAssertTrue(store.imageActionMessage?.contains("已裁剪封面图为 16:9") ?? false)
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = try temporaryDirectory()
    return directory.appendingPathComponent("workbench.json")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacImageBatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeTestImage(
    at url: URL,
    width: Int,
    height: Int,
    quality: CGFloat
  ) throws {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8((x * 37 + y * 19) % 256)
        pixels[offset + 1] = UInt8((x * 13 + y * 43) % 256)
        pixels[offset + 2] = UInt8((x * 59 + y * 7) % 256)
        pixels[offset + 3] = 255
      }
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      XCTFail("Failed to create test image")
      return
    }

    let options = [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary
    CGImageDestinationAddImage(destination, image, options)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
