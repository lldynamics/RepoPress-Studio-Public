import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PublishingWorkbenchCore

final class SiteImageWorkbenchServiceTests: XCTestCase {
  func testReportIgnoresVideoAttachments() {
    let profile = SiteProfile.defaultProfile
    let video = DraftAttachment(
      originalFilename: "walkthrough.mp4",
      relativePublishPath: "/videos/2026/walkthrough.mp4",
      repositoryPath: "static/videos/2026/walkthrough.mp4",
      altText: "",
      caption: "",
      sourceFilePath: "/tmp/missing-walkthrough.mp4"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Video Only",
      slug: "video-only",
      bodyMarkdown: "<video controls src=\"/videos/2026/walkthrough.mp4\"></video>",
      attachments: [video]
    )

    let report = SiteImageWorkbenchService().report(draft: draft, profile: profile)

    XCTAssertTrue(report.items.isEmpty)
    XCTAssertEqual(report.missingAltTextCount, 0)
    XCTAssertEqual(report.missingCaptionCount, 0)
    XCTAssertEqual(report.missingSourceCount, 0)
  }

  func testReportInspectsImagePublishReadiness() throws {
    let directory = try makeTemporaryDirectory()
    let imageURL = directory.appendingPathComponent("cover.png")
    try writeTestImage(at: imageURL, width: 3, height: 2, type: .png)

    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/2026/cover.png",
      repositoryPath: "static/images/2026/cover.png",
      altText: "",
      caption: "",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Image Report",
      slug: "image-report",
      coverAttachmentID: attachment.id,
      bodyMarkdown: """
      ![](/images/2026/cover.png)
      ![Missing](/images/2026/missing.png)
      """,
      attachments: [attachment]
    )

    let report = SiteImageWorkbenchService().report(draft: draft, profile: profile)

    XCTAssertEqual(report.items.count, 1)
    XCTAssertEqual(report.items.first?.dimensions, ImageDimensions(width: 3, height: 2))
    XCTAssertEqual(report.missingAltTextCount, 1)
    XCTAssertEqual(report.missingCaptionCount, 1)
    XCTAssertEqual(report.missingSourceCount, 0)
    XCTAssertEqual(report.duplicateImageCount, 0)
    XCTAssertEqual(report.webPConvertibleCount, 1)
    XCTAssertEqual(report.items.first?.isCover, true)
    XCTAssertEqual(report.items.first?.isReferencedInMarkdown, true)
    XCTAssertEqual(report.coverStatus.state, .ready)
    XCTAssertEqual(report.coverStatus.frontMatterFieldPath, "extra.og_preview_img")
    XCTAssertEqual(report.coverStatus.relativePublishPath, "/images/2026/cover.png")
    XCTAssertEqual(report.coverStatus.repositoryPath, "static/images/2026/cover.png")
    XCTAssertTrue(report.coverStatus.writesFrontMatter)
    XCTAssertTrue(report.issues.contains { $0.title == CoreL10n.text("正文图片未登记") })
  }

  func testReportFlagsDuplicateImageReferences() throws {
    let directory = try makeTemporaryDirectory()
    let imageURL = directory.appendingPathComponent("shared.png")
    try writeTestImage(at: imageURL, width: 8, height: 6, type: .png)

    let profile = SiteProfile.defaultProfile
    let first = DraftAttachment(
      originalFilename: "shared-a.png",
      relativePublishPath: "/images/2026/shared.png",
      repositoryPath: "static/images/2026/shared-a.png",
      altText: "Shared A",
      caption: "Shared A",
      sourceFilePath: imageURL.path
    )
    let second = DraftAttachment(
      originalFilename: "shared-b.png",
      relativePublishPath: "/images/2026/shared.png",
      repositoryPath: "static/images/2026/shared-b.png",
      altText: "Shared B",
      caption: "Shared B",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Duplicate Images",
      slug: "duplicate-images",
      bodyMarkdown: """
      ![First](/images/2026/shared.png)
      ![Again](/images/2026/shared.png)
      """,
      attachments: [first, second]
    )

    let report = SiteImageWorkbenchService().report(draft: draft, profile: profile)

    XCTAssertEqual(report.duplicateImageCount, 2)
    XCTAssertEqual(report.items.map(\.duplicateReferenceCount), [3, 3])
    XCTAssertTrue(report.issues.contains { $0.title == "图片发布路径重复" })
    XCTAssertTrue(report.issues.contains { $0.title == "源图重复使用" })
    XCTAssertTrue(report.issues.contains { $0.title == "正文重复引用图片" })
  }

  func testCoverStatusUsesFrameworkFieldAndKeepsPrivateCoverInspectable() throws {
    let directory = try makeTemporaryDirectory()
    let imageURL = directory.appendingPathComponent("private-cover.jpg")
    try writeTestImage(at: imageURL, width: 4, height: 3, type: .jpeg)

    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .jekyll)
    let attachment = DraftAttachment(
      originalFilename: "private-cover.jpg",
      relativePublishPath: "/assets/images/2026/private-cover.jpg",
      repositoryPath: "assets/images/2026/private-cover.jpg",
      altText: "Private cover",
      caption: "Private cover",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Private Cover",
      slug: "private-cover",
      visibility: .private,
      coverAttachmentID: attachment.id,
      bodyMarkdown: "![Private](/assets/images/2026/private-cover.jpg)",
      attachments: [attachment]
    )

    let report = SiteImageWorkbenchService().report(draft: draft, profile: profile)

    XCTAssertEqual(report.coverStatus.state, ImageCoverPublishState.privateSuppressed)
    XCTAssertEqual(report.coverStatus.frontMatterFieldPath, "image")
    XCTAssertEqual(report.coverStatus.relativePublishPath, "/assets/images/2026/private-cover.jpg")
    XCTAssertEqual(report.coverStatus.repositoryPath, "assets/images/2026/private-cover.jpg")
    XCTAssertTrue(report.coverStatus.fileExists)
    XCTAssertFalse(report.coverStatus.writesFrontMatter)
  }

  func testCoverStatusFlagsMissingCoverSourceFile() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "missing-cover.jpg",
      relativePublishPath: "/images/2026/missing-cover.jpg",
      repositoryPath: "static/images/2026/missing-cover.jpg",
      altText: "Missing cover",
      caption: "Missing cover",
      sourceFilePath: "/tmp/does-not-exist/missing-cover.jpg"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Missing Cover",
      slug: "missing-cover",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "![Missing](/images/2026/missing-cover.jpg)",
      attachments: [attachment]
    )

    let report = SiteImageWorkbenchService().report(draft: draft, profile: profile)

    XCTAssertEqual(report.coverStatus.state, .missingSource)
    XCTAssertEqual(report.coverStatus.frontMatterFieldPath, "extra.og_preview_img")
    XCTAssertEqual(report.coverStatus.repositoryPath, "static/images/2026/missing-cover.jpg")
    XCTAssertFalse(report.coverStatus.fileExists)
    XCTAssertFalse(report.coverStatus.writesFrontMatter)
  }

  func testFillMissingMetadataPreservesExistingValuesAndUpdatesEmptyMarkdownAlt() {
    let profile = SiteProfile.defaultProfile
    let first = DraftAttachment(
      originalFilename: "hero-image.jpg",
      relativePublishPath: "/images/2026/hero-image.jpg",
      repositoryPath: "static/images/2026/hero-image.jpg",
      altText: "",
      caption: ""
    )
    let second = DraftAttachment(
      originalFilename: "detail.jpg",
      relativePublishPath: "/images/2026/detail.jpg",
      repositoryPath: "static/images/2026/detail.jpg",
      altText: "Custom detail",
      caption: ""
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Metadata",
      slug: "metadata",
      bodyMarkdown: """
      ![](/images/2026/hero-image.jpg)
      ![Keep this](/images/2026/detail.jpg)
      """,
      attachments: [first, second]
    )

    let result = SiteImageWorkbenchService().fillMissingMetadata(draft: draft)

    XCTAssertEqual(result.filledAltTextCount, 1)
    XCTAssertEqual(result.filledCaptionCount, 2)
    XCTAssertEqual(result.updatedMarkdownReferenceCount, 1)
    XCTAssertEqual(result.draft.attachments[0].altText, "hero image")
    XCTAssertEqual(result.draft.attachments[0].caption, "hero image")
    XCTAssertEqual(result.draft.attachments[1].altText, "Custom detail")
    XCTAssertEqual(result.draft.attachments[1].caption, "Custom detail")
    XCTAssertTrue(result.draft.bodyMarkdown.contains("![hero image](/images/2026/hero-image.jpg)"))
    XCTAssertTrue(result.draft.bodyMarkdown.contains("![Keep this](/images/2026/detail.jpg)"))
  }

  func testFillMissingMetadataOnlyChangesIncludedAttachments() {
    let profile = SiteProfile.defaultProfile
    let included = DraftAttachment(
      originalFilename: "included-image.jpg",
      relativePublishPath: "/images/2026/included-image.jpg",
      repositoryPath: "static/images/2026/included-image.jpg"
    )
    let excluded = DraftAttachment(
      originalFilename: "excluded-image.jpg",
      relativePublishPath: "/images/2026/excluded-image.jpg",
      repositoryPath: "static/images/2026/excluded-image.jpg"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selective metadata",
      slug: "selective-metadata",
      bodyMarkdown: "![](/images/2026/included-image.jpg)\n![](/images/2026/excluded-image.jpg)",
      attachments: [included, excluded]
    )

    let result = SiteImageWorkbenchService().fillMissingMetadata(
      draft: draft,
      includedAttachmentIDs: [included.id]
    )

    XCTAssertEqual(result.filledAltTextCount, 1)
    XCTAssertEqual(result.filledCaptionCount, 1)
    XCTAssertEqual(result.draft.attachments[0].altText, "included image")
    XCTAssertEqual(result.draft.attachments[1].altText, "")
    XCTAssertTrue(result.draft.bodyMarkdown.contains("![included image](/images/2026/included-image.jpg)"))
    XCTAssertTrue(result.draft.bodyMarkdown.contains("![](/images/2026/excluded-image.jpg)"))
  }

  func testImageTextTargetsIncludeImagesMissingAltOrCaption() {
    let profile = SiteProfile.defaultProfile
    let missing = DraftAttachment(
      originalFilename: "workflow.png",
      relativePublishPath: "/images/2026/workflow.png",
      repositoryPath: "static/images/2026/workflow.png",
      altText: "",
      caption: ""
    )
    let complete = DraftAttachment(
      originalFilename: "complete.png",
      relativePublishPath: "/images/2026/complete.png",
      repositoryPath: "static/images/2026/complete.png",
      altText: "Complete",
      caption: "Complete"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Image AI",
      slug: "image-ai",
      summary: "Use AI to improve image text.",
      coverAttachmentID: missing.id,
      bodyMarkdown: """
      ![](/images/2026/workflow.png)
      ![Complete](/images/2026/complete.png)
      """,
      attachments: [missing, complete]
    )

    let service = SiteImageWorkbenchService()
    let targets = service.imageTextTargets(draft: draft, profile: profile)

    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets[0].attachmentID, missing.id)
    XCTAssertEqual(targets[0].id, missing.id.uuidString)
    XCTAssertEqual(targets[0].draftTitle, "Image AI")
    XCTAssertEqual(targets[0].markdownPath, profile.markdownPath(for: draft))
    XCTAssertEqual(targets[0].imagePath, "/images/2026/workflow.png")
    XCTAssertTrue(targets[0].isCover)
    XCTAssertTrue(targets[0].isReferencedInMarkdown)
  }

  func testAIImageTextGenerationAvailabilityMatchesMobileWorkbenchStates() {
    let remoteConfig = AIProviderConfig(requiresAPIKey: true)
    let localConfig = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-model",
      requiresAPIKey: false
    )

    XCTAssertEqual(
      AIImageTextGenerationAvailabilityService.presentation(
        targetCount: 2,
        isGenerating: false,
        aiProviderConfig: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: true)
      ),
      AIImageTextGenerationAvailabilityPresentation(isEnabled: true)
    )
    XCTAssertEqual(
      AIImageTextGenerationAvailabilityService.presentation(
        targetCount: 0,
        isGenerating: false,
        aiProviderConfig: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: true)
      ),
      AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "当前文章没有缺少 alt/caption 的图片"
      )
    )
    XCTAssertEqual(
      AIImageTextGenerationAvailabilityService.presentation(
        targetCount: 1,
        isGenerating: true,
        aiProviderConfig: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: true)
      ),
      AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "AI 正在生成图片文案"
      )
    )
    XCTAssertEqual(
      AIImageTextGenerationAvailabilityService.presentation(
        targetCount: 1,
        isGenerating: false,
        aiProviderConfig: remoteConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: false)
      ),
      AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "需要先启用 AI"
      )
    )
    XCTAssertEqual(
      AIImageTextGenerationAvailabilityService.presentation(
        targetCount: 1,
        isGenerating: false,
        aiProviderConfig: localConfig,
        aiTokenAvailability: KeychainTokenAvailability(hasToken: false)
      ),
      AIImageTextGenerationAvailabilityPresentation(isEnabled: true)
    )
  }

  func testApplyImageTextSuggestionsFillsMissingFieldsAndMarkdownAlt() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "workflow.png",
      relativePublishPath: "/images/2026/workflow.png",
      repositoryPath: "static/images/2026/workflow.png",
      altText: "",
      caption: ""
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Apply AI Image Text",
      slug: "apply-ai-image-text",
      bodyMarkdown: "![](/images/2026/workflow.png)",
      attachments: [attachment]
    )
    let suggestion = AIPublishingImageTextSuggestion(
      id: attachment.id.uuidString,
      draftID: draft.id,
      attachmentID: attachment.id,
      filename: "workflow.png",
      imagePath: "/images/2026/workflow.png",
      altText: "用于说明图片发布工作流的截图",
      caption: "图片工作台检查发布前图片字段。",
      reason: "基于文章上下文生成。"
    )

    let result = SiteImageWorkbenchService().applyImageTextSuggestions([suggestion], to: draft)

    XCTAssertEqual(result.appliedAltTextCount, 1)
    XCTAssertEqual(result.appliedCaptionCount, 1)
    XCTAssertEqual(result.updatedMarkdownReferenceCount, 1)
    XCTAssertEqual(result.changedCount, 3)
    XCTAssertEqual(result.draft.attachments[0].altText, "用于说明图片发布工作流的截图")
    XCTAssertEqual(result.draft.attachments[0].caption, "图片工作台检查发布前图片字段。")
    XCTAssertEqual(result.draft.bodyMarkdown, "![用于说明图片发布工作流的截图](/images/2026/workflow.png)")
  }

  func testApplyImageTextSuggestionsPreservesExistingAttachmentText() {
    let attachment = DraftAttachment(
      originalFilename: "workflow.png",
      relativePublishPath: "/images/2026/workflow.png",
      repositoryPath: "static/images/2026/workflow.png",
      altText: "Existing alt",
      caption: "Existing caption"
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Preserve Existing",
      slug: "preserve-existing",
      bodyMarkdown: "![](/images/2026/workflow.png)",
      attachments: [attachment]
    )
    let suggestion = AIPublishingImageTextSuggestion(
      id: attachment.id.uuidString,
      draftID: draft.id,
      attachmentID: attachment.id,
      filename: "workflow.png",
      imagePath: "/images/2026/workflow.png",
      altText: "Suggested alt",
      caption: "Suggested caption",
      reason: ""
    )

    let result = SiteImageWorkbenchService().applyImageTextSuggestions([suggestion], to: draft)

    XCTAssertEqual(result.appliedAltTextCount, 0)
    XCTAssertEqual(result.appliedCaptionCount, 0)
    XCTAssertEqual(result.updatedMarkdownReferenceCount, 1)
    XCTAssertEqual(result.draft.attachments[0].altText, "Existing alt")
    XCTAssertEqual(result.draft.attachments[0].caption, "Existing caption")
    XCTAssertEqual(result.draft.bodyMarkdown, "![Existing alt](/images/2026/workflow.png)")
  }

  func testOptimizeJPEGCreatesSmallerCopyWithoutOverwritingOriginal() throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("noisy.jpg")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    try writeTestImage(at: sourceURL, width: 360, height: 360, type: .jpeg, quality: 1.0)
    let originalData = try Data(contentsOf: sourceURL)

    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "noisy.jpg",
      relativePublishPath: "/images/2026/noisy.jpg",
      repositoryPath: "static/images/2026/noisy.jpg",
      byteSize: Int64(originalData.count),
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Optimization",
      slug: "optimization",
      bodyMarkdown: "![Noisy](/images/2026/noisy.jpg)",
      attachments: [attachment]
    )

    let result = try SiteImageWorkbenchService().optimizeJPEGAttachments(
      draft: draft,
      destinationDirectory: optimizedDirectory,
      quality: 0.25
    )

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertGreaterThan(result.savedBytes, 0)
    XCTAssertNotEqual(result.draft.attachments[0].sourceFilePath, sourceURL.path)
    XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
  }

  func testOptimizeJPEGSkipsExcludedAttachment() throws {
    let directory = try makeTemporaryDirectory()
    let includedURL = directory.appendingPathComponent("included.jpg")
    let excludedURL = directory.appendingPathComponent("excluded.jpg")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    try writeTestImage(at: includedURL, width: 360, height: 360, type: .jpeg, quality: 1)
    try writeTestImage(at: excludedURL, width: 360, height: 360, type: .jpeg, quality: 1)

    let profile = SiteProfile.defaultProfile
    let included = DraftAttachment(
      originalFilename: "included.jpg",
      relativePublishPath: "/images/2026/included.jpg",
      repositoryPath: "static/images/2026/included.jpg",
      sourceFilePath: includedURL.path
    )
    let excluded = DraftAttachment(
      originalFilename: "excluded.jpg",
      relativePublishPath: "/images/2026/excluded.jpg",
      repositoryPath: "static/images/2026/excluded.jpg",
      sourceFilePath: excludedURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selective optimization",
      slug: "selective-optimization",
      attachments: [included, excluded]
    )

    let result = try SiteImageWorkbenchService().optimizeJPEGAttachments(
      draft: draft,
      destinationDirectory: optimizedDirectory,
      quality: 0.25,
      includedAttachmentIDs: [included.id]
    )

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertNotEqual(result.draft.attachments[0].sourceFilePath, includedURL.path)
    XCTAssertEqual(result.draft.attachments[1].sourceFilePath, excludedURL.path)
  }

  func testConvertAttachmentsToWebPUpdatesPathsAndMarkdownReferences() throws {
    guard SiteImageWorkbenchService.supportsWebPEncoding else {
      throw XCTSkip("当前运行环境没有可用的 WebP 编码器。")
    }

    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("diagram.png")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    try writeTestImage(at: sourceURL, width: 96, height: 64, type: .png)

    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "diagram.png",
      relativePublishPath: "/images/2026/diagram.png",
      repositoryPath: "static/images/2026/diagram.png",
      altText: "Diagram",
      caption: "Diagram",
      byteSize: Int64((try Data(contentsOf: sourceURL)).count),
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "WebP Conversion",
      slug: "webp-conversion",
      bodyMarkdown: """
      ![Diagram](/images/2026/diagram.png)
      ![Titled](/images/2026/diagram.png "diagram title")
      """,
      attachments: [attachment]
    )

    let result = try SiteImageWorkbenchService().convertAttachmentsToWebP(
      draft: draft,
      destinationDirectory: optimizedDirectory,
      quality: 0.75
    )

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertEqual(result.draft.attachments[0].originalFilename, "diagram.webp")
    XCTAssertEqual(result.draft.attachments[0].relativePublishPath, "/images/2026/diagram.webp")
    XCTAssertEqual(result.draft.attachments[0].repositoryPath, "static/images/2026/diagram.webp")
    XCTAssertEqual(URL(fileURLWithPath: result.draft.attachments[0].sourceFilePath ?? "").pathExtension, "webp")
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.draft.attachments[0].sourceFilePath ?? ""))
    XCTAssertTrue(result.draft.bodyMarkdown.contains("![Diagram](/images/2026/diagram.webp)"))
    XCTAssertTrue(result.draft.bodyMarkdown.contains("![Titled](/images/2026/diagram.webp \"diagram title\")"))
  }

  func testCWebPTimeoutStopsProcessAndCleansPartialOutput() throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("diagram.png")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    let executableURL = directory.appendingPathComponent("slow-cwebp")
    try writeTestImage(at: sourceURL, width: 32, height: 24, type: .png)
    try "#!/bin/sh\nsleep 3\n".write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let attachment = DraftAttachment(
      originalFilename: "diagram.png",
      relativePublishPath: "/images/2026/diagram.png",
      repositoryPath: "static/images/2026/diagram.png",
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Timeout",
      slug: "timeout",
      bodyMarkdown: "![Diagram](/images/2026/diagram.png)",
      attachments: [attachment]
    )
    let service = SiteImageWorkbenchService(
      cwebPExecutableURL: executableURL,
      cwebPTimeout: 0.1,
      prefersCWebP: true
    )

    let startedAt = Date()
    XCTAssertThrowsError(
      try service.convertAttachmentsToWebP(draft: draft, destinationDirectory: optimizedDirectory)
    ) { error in
      XCTAssertEqual((error as? ImageWorkbenchError)?.errorDescription, "cwebp 执行超时，已停止。")
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.8)
    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: optimizedDirectory.path)
    XCTAssertTrue(remainingFiles.isEmpty)
  }

  func testImageBatchCancellationStopsCWebPAndCleansStagingDirectory() async throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("diagram.png")
    let executableURL = directory.appendingPathComponent("slow-cwebp")
    try writeTestImage(at: sourceURL, width: 32, height: 24, type: .png)
    try "#!/bin/sh\nsleep 3\n".write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let attachment = DraftAttachment(
      originalFilename: "diagram.png",
      relativePublishPath: "/images/2026/diagram.png",
      repositoryPath: "static/images/2026/diagram.png",
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Cancellation",
      slug: "cancellation",
      bodyMarkdown: "![Diagram](/images/2026/diagram.png)",
      attachments: [attachment]
    )
    let processor = ImageBatchProcessingActor(
      service: SiteImageWorkbenchService(
        cwebPExecutableURL: executableURL,
        cwebPTimeout: 3,
        prefersCWebP: true
      )
    )
    let cancellationToken = ImageProcessingCancellationToken()
    let task = Task {
      try await processor.process(
        operation: .convertWebP,
        drafts: [draft],
        destinationRoot: directory,
        cancellationToken: cancellationToken,
        progress: { _ in }
      )
    }

    try await Task.sleep(for: .milliseconds(100))
    cancellationToken.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected: the token is observed while cwebp is running.
    }

    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertFalse(remainingFiles.contains { $0.hasPrefix(".image-batch-") })
  }

  func testOptimizeSVGCreatesSmallerCopyWithoutChangingPublishPath() throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("diagram.svg")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    let sourceSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
      <!-- exported by design tool -->
      <g>
        <rect width="120" height="80" fill="#fff" />
      </g>
    </svg>
    """
    try sourceSVG.write(to: sourceURL, atomically: true, encoding: .utf8)

    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "diagram.svg",
      relativePublishPath: "/images/2026/diagram.svg",
      repositoryPath: "static/images/2026/diagram.svg",
      altText: "Diagram",
      caption: "Diagram",
      byteSize: Int64(Data(sourceSVG.utf8).count),
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "SVG Optimization",
      slug: "svg-optimization",
      bodyMarkdown: "![Diagram](/images/2026/diagram.svg)",
      attachments: [attachment]
    )

    let report = SiteImageWorkbenchService().report(draft: draft, profile: profile)
    XCTAssertEqual(report.optimizableSVGCount, 1)

    let result = try SiteImageWorkbenchService().optimizeSVGAttachments(
      draft: draft,
      destinationDirectory: optimizedDirectory
    )

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertGreaterThan(result.savedBytes, 0)
    XCTAssertEqual(result.draft.attachments[0].relativePublishPath, "/images/2026/diagram.svg")
    XCTAssertEqual(result.draft.attachments[0].repositoryPath, "static/images/2026/diagram.svg")
    XCTAssertNotEqual(result.draft.attachments[0].sourceFilePath, sourceURL.path)
    let optimizedText = try String(contentsOfFile: result.draft.attachments[0].sourceFilePath ?? "", encoding: .utf8)
    XCTAssertFalse(optimizedText.contains("exported by design tool"))
  }

  func testResizeLargeAttachmentsCreatesScaledCopyWithoutChangingPublishPath() throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("large.jpg")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    try writeTestImage(at: sourceURL, width: 320, height: 160, type: .jpeg, quality: 0.95)

    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "large.jpg",
      relativePublishPath: "/images/2026/large.jpg",
      repositoryPath: "static/images/2026/large.jpg",
      altText: "Large",
      caption: "Large",
      byteSize: Int64((try Data(contentsOf: sourceURL)).count),
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Resize",
      slug: "resize",
      bodyMarkdown: "![Large](/images/2026/large.jpg)",
      attachments: [attachment]
    )

    let result = try SiteImageWorkbenchService().resizeLargeAttachments(
      draft: draft,
      destinationDirectory: optimizedDirectory,
      maxPixelDimension: 160,
      quality: 0.8
    )
    let resizedURL = URL(fileURLWithPath: result.draft.attachments[0].sourceFilePath ?? "")
    let resizedDimensions = CGImageSourceCreateWithURL(resizedURL as CFURL, nil)
      .flatMap { source -> ImageDimensions? in
        guard
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
          return nil
        }
        return ImageDimensions(width: width.intValue, height: height.intValue)
      }

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertEqual(result.draft.attachments[0].relativePublishPath, "/images/2026/large.jpg")
    XCTAssertEqual(result.draft.attachments[0].repositoryPath, "static/images/2026/large.jpg")
    XCTAssertNotEqual(result.draft.attachments[0].sourceFilePath, sourceURL.path)
    XCTAssertEqual(resizedDimensions, ImageDimensions(width: 160, height: 80))
  }

  func testCropAttachmentToAspectRatioCreatesCroppedCopyWithoutChangingPublishPath() throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("portrait-cover.jpg")
    let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
    try writeTestImage(at: sourceURL, width: 300, height: 300, type: .jpeg, quality: 0.95)

    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "portrait-cover.jpg",
      relativePublishPath: "/images/2026/portrait-cover.jpg",
      repositoryPath: "static/images/2026/portrait-cover.jpg",
      altText: "Cover",
      caption: "Cover",
      byteSize: Int64((try Data(contentsOf: sourceURL)).count),
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Crop Cover",
      slug: "crop-cover",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "![Cover](/images/2026/portrait-cover.jpg)",
      attachments: [attachment]
    )

    let result = try SiteImageWorkbenchService().cropAttachmentToAspectRatio(
      draft: draft,
      attachmentID: attachment.id,
      destinationDirectory: optimizedDirectory,
      aspectWidth: 16,
      aspectHeight: 9
    )
    let croppedURL = URL(fileURLWithPath: result.draft.attachments[0].sourceFilePath ?? "")
    let croppedDimensions = CGImageSourceCreateWithURL(croppedURL as CFURL, nil)
      .flatMap { source -> ImageDimensions? in
        guard
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
          return nil
        }
        return ImageDimensions(width: width.intValue, height: height.intValue)
      }

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertEqual(result.draft.attachments[0].relativePublishPath, "/images/2026/portrait-cover.jpg")
    XCTAssertEqual(result.draft.attachments[0].repositoryPath, "static/images/2026/portrait-cover.jpg")
    XCTAssertNotEqual(result.draft.attachments[0].sourceFilePath, sourceURL.path)
    XCTAssertEqual(croppedDimensions, ImageDimensions(width: 300, height: 168))
  }

  func testCropRejectsOversizedImageMetadataBeforePixelDecode() throws {
    let unsafeDimensions = [
      (width: SiteImageWorkbenchService.maximumSafeInputPixelDimension + 1, height: 10),
      (width: 10_000, height: 10_000),
    ]

    for dimensions in unsafeDimensions {
      let directory = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let sourceURL = directory.appendingPathComponent("oversized.jpg")
      let optimizedDirectory = directory.appendingPathComponent("optimized", isDirectory: true)
      try writeJPEGWithPatchedDimensions(
        at: sourceURL,
        width: dimensions.width,
        height: dimensions.height
      )
      let attachment = DraftAttachment(
        originalFilename: "oversized.jpg",
        relativePublishPath: "/images/oversized.jpg",
        repositoryPath: "static/images/oversized.jpg",
        altText: "Oversized",
        caption: "Oversized",
        byteSize: Int64((try Data(contentsOf: sourceURL)).count),
        sourceFilePath: sourceURL.path
      )
      let draft = ArticleDraft(
        siteProfileID: SiteProfile.defaultProfile.id,
        title: "Oversized",
        slug: "oversized",
        bodyMarkdown: "![Oversized](/images/oversized.jpg)",
        attachments: [attachment]
      )

      XCTAssertThrowsError(
        try SiteImageWorkbenchService().cropAttachmentToAspectRatio(
          draft: draft,
          attachmentID: attachment.id,
          destinationDirectory: optimizedDirectory
        )
      ) { error in
        guard case let .unsafeImageDimensions(filename, width, height)? = error as? ImageWorkbenchError else {
          return XCTFail("Expected unsafeImageDimensions, got \(error)")
        }
        XCTAssertEqual(filename, "oversized.jpg")
        XCTAssertEqual(width, dimensions.width)
        XCTAssertEqual(height, dimensions.height)
      }
    }
  }

  func testCropRejectsInvalidAspectBeforeOversizedImageDecode() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("oversized.jpg")
    try writeJPEGWithPatchedDimensions(
      at: sourceURL,
      width: SiteImageWorkbenchService.maximumSafeInputPixelDimension + 1,
      height: 10
    )
    let attachment = DraftAttachment(
      originalFilename: "oversized.jpg",
      relativePublishPath: "/images/oversized.jpg",
      repositoryPath: "static/images/oversized.jpg",
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Invalid crop",
      slug: "invalid-crop",
      attachments: [attachment]
    )

    XCTAssertThrowsError(
      try SiteImageWorkbenchService().cropAttachmentToAspectRatio(
        draft: draft,
        attachmentID: attachment.id,
        destinationDirectory: directory.appendingPathComponent("optimized"),
        aspectWidth: 0,
        aspectHeight: 9
      )
    ) { error in
      guard case .cannotCreateOptimizedImage("oversized.jpg")? = error as? ImageWorkbenchError else {
        return XCTFail("Expected invalid aspect to fail before dimension validation, got \(error)")
      }
    }
  }

  func testCropDownsamplesLargeSourceToBoundedWorkingDimension() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("wide.jpg")
    try writeTestImage(at: sourceURL, width: 5_000, height: 100, type: .jpeg)
    let attachment = DraftAttachment(
      originalFilename: "wide.jpg",
      relativePublishPath: "/images/wide.jpg",
      repositoryPath: "static/images/wide.jpg",
      sourceFilePath: sourceURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Bounded crop",
      slug: "bounded-crop",
      attachments: [attachment]
    )

    let result = try SiteImageWorkbenchService().cropAttachmentToAspectRatio(
      draft: draft,
      attachmentID: attachment.id,
      destinationDirectory: directory.appendingPathComponent("optimized"),
      aspectWidth: 50,
      aspectHeight: 1
    )
    let outputPath = try XCTUnwrap(result.draft.attachments.first?.sourceFilePath)
    let outputURL = URL(fileURLWithPath: outputPath)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
    let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue

    XCTAssertEqual(result.optimizedCount, 1)
    XCTAssertLessThanOrEqual(max(width, height), SiteImageWorkbenchService.maximumCropWorkingPixelDimension)
    XCTAssertEqual(width, SiteImageWorkbenchService.maximumCropWorkingPixelDimension)
  }

  func testSiteSummaryAggregatesImagesAcrossDrafts() throws {
    let directory = try makeTemporaryDirectory()
    let imageURL = directory.appendingPathComponent("hero.jpg")
    try writeTestImage(at: imageURL, width: 32, height: 32, type: .jpeg, quality: 0.9)

    let profile = SiteProfile.defaultProfile
    let firstAttachment = DraftAttachment(
      originalFilename: "hero.jpg",
      relativePublishPath: "/images/2026/hero.jpg",
      repositoryPath: "static/images/2026/hero.jpg",
      altText: "",
      caption: "",
      byteSize: Int64((try Data(contentsOf: imageURL)).count),
      sourceFilePath: imageURL.path
    )
    let secondAttachment = DraftAttachment(
      originalFilename: "missing.png",
      relativePublishPath: "/images/2026/missing.png",
      repositoryPath: "static/images/2026/missing.png",
      altText: "Missing",
      caption: "",
      byteSize: 12,
      sourceFilePath: directory.appendingPathComponent("missing.png").path
    )
    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: "![Hero](/images/2026/hero.jpg)",
      attachments: [firstAttachment]
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: "![Missing](/images/2026/missing.png)",
      attachments: [secondAttachment]
    )

    let summary = SiteImageWorkbenchService().siteSummary(
      drafts: [firstDraft, secondDraft],
      profile: profile
    )

    XCTAssertEqual(summary.draftCount, 2)
    XCTAssertEqual(summary.imageCount, 2)
    XCTAssertEqual(summary.missingAltTextCount, 1)
    XCTAssertEqual(summary.missingCaptionCount, 2)
    XCTAssertEqual(summary.missingSourceCount, 1)
    XCTAssertEqual(summary.optimizableJPEGCount, 1)
    XCTAssertEqual(summary.webPConvertibleCount, 1)
    XCTAssertEqual(summary.duplicateImageCount, 0)
    XCTAssertEqual(summary.draftSummaries.count, 2)
    let firstDraftSummary = try XCTUnwrap(
      summary.draftSummaries.first(where: { $0.draftID == firstDraft.id })
    )
    XCTAssertEqual(firstDraftSummary.items.map(\.attachmentID), [firstAttachment.id])
    XCTAssertFalse(firstDraftSummary.issues.isEmpty)
    let secondDraftSummary = try XCTUnwrap(
      summary.draftSummaries.first(where: { $0.draftID == secondDraft.id })
    )
    XCTAssertEqual(secondDraftSummary.items.map(\.attachmentID), [secondAttachment.id])
    XCTAssertTrue(secondDraftSummary.issues.contains { $0.attachmentID == secondAttachment.id })
  }

  func testSiteSummarySortsImageQueueBySeverity() throws {
    let directory = try makeTemporaryDirectory()
    let warningURL = directory.appendingPathComponent("warning.jpg")
    let cleanURL = directory.appendingPathComponent("clean.jpg")
    try writeTestImage(at: warningURL, width: 32, height: 32, type: .jpeg, quality: 0.9)
    try writeTestImage(at: cleanURL, width: 32, height: 32, type: .jpeg, quality: 0.9)

    let profile = SiteProfile.defaultProfile
    let errorAttachment = DraftAttachment(
      originalFilename: "missing.jpg",
      relativePublishPath: "/images/2026/missing.jpg",
      repositoryPath: "static/images/2026/missing.jpg",
      altText: "Missing",
      caption: "Missing",
      sourceFilePath: directory.appendingPathComponent("missing.jpg").path
    )
    let warningAttachment = DraftAttachment(
      originalFilename: "warning.jpg",
      relativePublishPath: "/images/2026/warning.jpg",
      repositoryPath: "static/images/2026/warning.jpg",
      altText: "",
      caption: "",
      sourceFilePath: warningURL.path
    )
    let cleanAttachment = DraftAttachment(
      originalFilename: "clean.jpg",
      relativePublishPath: "/images/2026/clean.jpg",
      repositoryPath: "static/images/2026/clean.jpg",
      altText: "Clean",
      caption: "Clean",
      sourceFilePath: cleanURL.path
    )

    let errorDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "A Error",
      slug: "a-error",
      bodyMarkdown: "![Missing](/images/2026/missing.jpg)",
      attachments: [errorAttachment]
    )
    let warningDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "B Warning",
      slug: "b-warning",
      bodyMarkdown: "![](/images/2026/warning.jpg)",
      attachments: [warningAttachment]
    )
    let cleanDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "C Clean",
      slug: "c-clean",
      bodyMarkdown: "![Clean](/images/2026/clean.jpg)",
      attachments: [cleanAttachment]
    )

    let summary = SiteImageWorkbenchService().siteSummary(
      drafts: [cleanDraft, warningDraft, errorDraft],
      profile: profile
    )

    XCTAssertEqual(summary.draftSummaries.map(\.draftTitle), ["A Error", "B Warning", "C Clean"])
    XCTAssertEqual(summary.draftSummaries.map(\.errorCount), [1, 0, 0])
    XCTAssertEqual(summary.draftSummaries.map(\.warningCount), [0, 1, 0])
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeJPEGWithPatchedDimensions(at url: URL, width: Int, height: Int) throws {
    try writeTestImage(at: url, width: 1, height: 1, type: .jpeg)
    var data = try Data(contentsOf: url)
    guard data.count >= 12, data[0] == 0xFF, data[1] == 0xD8 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var offset = 2
    var didPatchDimensions = false
    let startOfFrameMarkers: Set<UInt8> = [
      0xC0, 0xC1, 0xC2, 0xC3,
      0xC5, 0xC6, 0xC7,
      0xC9, 0xCA, 0xCB,
      0xCD, 0xCE, 0xCF,
    ]
    while offset + 9 < data.count {
      guard data[offset] == 0xFF else {
        offset += 1
        continue
      }
      let marker = data[offset + 1]
      if marker == 0xD9 || marker == 0xDA { break }
      if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
        offset += 2
        continue
      }
      let segmentLength = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      guard segmentLength >= 2, offset + 2 + segmentLength <= data.count else {
        throw CocoaError(.fileReadCorruptFile)
      }
      if startOfFrameMarkers.contains(marker) {
        writeJPEGUInt16(UInt16(height), to: &data, at: offset + 5)
        writeJPEGUInt16(UInt16(width), to: &data, at: offset + 7)
        didPatchDimensions = true
        break
      }
      offset += 2 + segmentLength
    }
    guard didPatchDimensions else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try data.write(to: url)
  }

  private func writeJPEGUInt16(
    _ value: UInt16,
    to data: inout Data,
    at offset: Int
  ) {
    data[offset] = UInt8(value >> 8)
    data[offset + 1] = UInt8(value & 0xFF)
  }

  private func writeTestImage(
    at url: URL,
    width: Int,
    height: Int,
    type: UTType,
    quality: CGFloat = 0.9
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
      let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
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
