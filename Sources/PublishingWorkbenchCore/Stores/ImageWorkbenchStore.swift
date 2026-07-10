import Combine
import Foundation

@MainActor
public final class ImageWorkbenchStore: ObservableObject {
  private unowned let store: WorkbenchStore
  private let imageWorkbenchService: SiteImageWorkbenchService
  private let persistence: WorkbenchPersistence

  init(
    store: WorkbenchStore,
    imageWorkbenchService: SiteImageWorkbenchService,
    persistence: WorkbenchPersistence
  ) {
    self.store = store
    self.imageWorkbenchService = imageWorkbenchService
    self.persistence = persistence
  }

  private var selectedDraft: ArticleDraft? {
    store.selectedDraft
  }

  private var visibleDrafts: [ArticleDraft] {
    store.visibleDrafts
  }

  private var drafts: [ArticleDraft] {
    get { store.drafts }
    set { store.setDrafts(newValue) }
  }

  private var imageWorkbenchReport: ImageWorkbenchReport? {
    get { store.imageWorkbenchReport }
    set { store.setImageWorkbenchReport(newValue) }
  }

  private var imageActionMessage: String? {
    get { store.imageActionMessage }
    set { store.setImageActionMessage(newValue) }
  }

  private func profile(for draft: ArticleDraft) -> SiteProfile {
    store.profile(for: draft)
  }

  private func updateDraft(_ draft: ArticleDraft) {
    store.updateDraft(draft)
  }

  private func runPreflight() {
    store.runPreflight()
  }

  private func save() {
    store.save()
  }

  public func refreshImageWorkbenchReport() {
    guard let selectedDraft else {
      imageWorkbenchReport = nil
      return
    }

    imageWorkbenchReport = imageWorkbenchService.report(
      draft: selectedDraft,
      profile: profile(for: selectedDraft)
    )
  }

  public func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    imageWorkbenchService.report(draft: draft, profile: profile(for: draft))
  }

  public func imageTextTargetCount(for draft: ArticleDraft, report: ImageWorkbenchReport?) -> Int {
    imageWorkbenchService.imageTextTargets(
      draft: draft,
      profile: profile(for: draft),
      report: report
    ).count
  }

  public func fillMissingImageMetadataForSelectedDraft() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    let result = imageWorkbenchService.fillMissingMetadata(draft: selectedDraft)
    let changedCount = result.filledAltTextCount
      + result.filledCaptionCount
      + result.updatedMarkdownReferenceCount

    guard changedCount > 0 else {
      imageActionMessage = "没有需要补全的图片元数据。"
      refreshImageWorkbenchReport()
      return
    }

    updateDraft(result.draft)
    refreshImageWorkbenchReport()
    save()
    imageActionMessage = "已补全 \(result.filledAltTextCount) 个 alt、\(result.filledCaptionCount) 个 caption，更新 \(result.updatedMarkdownReferenceCount) 处正文引用。"
  }

  public func fillMissingImageMetadataForVisibleDrafts() {
    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var filledAltTextCount = 0
    var filledCaptionCount = 0
    var updatedMarkdownReferenceCount = 0

    for draft in visibleDrafts {
      let result = imageWorkbenchService.fillMissingMetadata(draft: draft)
      let changedCount = result.filledAltTextCount
        + result.filledCaptionCount
        + result.updatedMarkdownReferenceCount
      guard changedCount > 0 else { continue }

      updatedDraftsByID[draft.id] = result.draft
      filledAltTextCount += result.filledAltTextCount
      filledCaptionCount += result.filledCaptionCount
      updatedMarkdownReferenceCount += result.updatedMarkdownReferenceCount
    }

    guard !updatedDraftsByID.isEmpty else {
      imageActionMessage = "当前 Profile 没有需要补全的图片元数据。"
      refreshImageWorkbenchReport()
      return
    }

    drafts = drafts.map { updatedDraftsByID[$0.id] ?? $0 }
    runPreflight()
    refreshImageWorkbenchReport()
    save()
    imageActionMessage = "已批量补全 \(filledAltTextCount) 个 alt、\(filledCaptionCount) 个 caption，更新 \(updatedMarkdownReferenceCount) 处正文引用。"
  }

  public func optimizeSelectedDraftJPEGImages() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    do {
      let result = try imageWorkbenchService.optimizeJPEGAttachments(
        draft: selectedDraft,
        destinationDirectory: persistence.imageOptimizationDirectoryURL
      )

      if result.optimizedCount > 0 {
        updateDraft(result.draft)
        save()
      }

      refreshImageWorkbenchReport()

      if result.optimizedCount == 0 {
        imageActionMessage = result.messages.first ?? "没有可压缩的 JPEG 图片。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
        imageActionMessage = "已生成 \(result.optimizedCount) 个优化副本，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "图片压缩失败：\(error.localizedDescription)"
    }
  }

  public func optimizeVisibleDraftJPEGImages() {
    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var optimizedCount = 0
    var savedBytes: Int64 = 0
    var firstMessage: String?

    do {
      for draft in visibleDrafts {
        let result = try imageWorkbenchService.optimizeJPEGAttachments(
          draft: draft,
          destinationDirectory: persistence.imageOptimizationDirectoryURL
        )

        if result.optimizedCount > 0 {
          updatedDraftsByID[draft.id] = result.draft
          optimizedCount += result.optimizedCount
          savedBytes += result.savedBytes
        } else if firstMessage == nil {
          firstMessage = result.messages.first
        }
      }

      if !updatedDraftsByID.isEmpty {
        drafts = drafts.map { updatedDraftsByID[$0.id] ?? $0 }
        runPreflight()
        refreshImageWorkbenchReport()
        save()
      } else {
        refreshImageWorkbenchReport()
      }

      if optimizedCount == 0 {
        imageActionMessage = firstMessage ?? "当前 Profile 没有可压缩的 JPEG 图片。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        imageActionMessage = "已批量生成 \(optimizedCount) 个优化副本，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "批量图片压缩失败：\(error.localizedDescription)"
    }
  }

  public func convertSelectedDraftImagesToWebP() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    do {
      let result = try imageWorkbenchService.convertAttachmentsToWebP(
        draft: selectedDraft,
        destinationDirectory: persistence.imageOptimizationDirectoryURL
      )

      if result.optimizedCount > 0 {
        updateDraft(result.draft)
        save()
      }

      refreshImageWorkbenchReport()

      if result.optimizedCount == 0 {
        imageActionMessage = result.messages.first ?? "没有可转换为 WebP 的图片。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
        imageActionMessage = "已转换 \(result.optimizedCount) 张 WebP 图片，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "WebP 转换失败：\(error.localizedDescription)"
    }
  }

  public func convertVisibleDraftImagesToWebP() {
    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var convertedCount = 0
    var savedBytes: Int64 = 0
    var firstMessage: String?

    do {
      for draft in visibleDrafts {
        let result = try imageWorkbenchService.convertAttachmentsToWebP(
          draft: draft,
          destinationDirectory: persistence.imageOptimizationDirectoryURL
        )

        if result.optimizedCount > 0 {
          updatedDraftsByID[draft.id] = result.draft
          convertedCount += result.optimizedCount
          savedBytes += result.savedBytes
        } else if firstMessage == nil {
          firstMessage = result.messages.first
        }
      }

      if !updatedDraftsByID.isEmpty {
        drafts = drafts.map { updatedDraftsByID[$0.id] ?? $0 }
        runPreflight()
        refreshImageWorkbenchReport()
        save()
      } else {
        refreshImageWorkbenchReport()
      }

      if convertedCount == 0 {
        imageActionMessage = firstMessage ?? "当前 Profile 没有可转换为 WebP 的图片。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        imageActionMessage = "已批量转换 \(convertedCount) 张 WebP 图片，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "批量 WebP 转换失败：\(error.localizedDescription)"
    }
  }

  public func optimizeSelectedDraftSVGImages() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    do {
      let result = try imageWorkbenchService.optimizeSVGAttachments(
        draft: selectedDraft,
        destinationDirectory: persistence.imageOptimizationDirectoryURL
      )

      if result.optimizedCount > 0 {
        updateDraft(result.draft)
        save()
      }

      refreshImageWorkbenchReport()

      if result.optimizedCount == 0 {
        imageActionMessage = result.messages.first ?? "没有可优化的 SVG 图片。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
        imageActionMessage = "已优化 \(result.optimizedCount) 个 SVG 副本，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "SVG 优化失败：\(error.localizedDescription)"
    }
  }

  public func optimizeVisibleDraftSVGImages() {
    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var optimizedCount = 0
    var savedBytes: Int64 = 0
    var firstMessage: String?

    do {
      for draft in visibleDrafts {
        let result = try imageWorkbenchService.optimizeSVGAttachments(
          draft: draft,
          destinationDirectory: persistence.imageOptimizationDirectoryURL
        )

        if result.optimizedCount > 0 {
          updatedDraftsByID[draft.id] = result.draft
          optimizedCount += result.optimizedCount
          savedBytes += result.savedBytes
        } else if firstMessage == nil {
          firstMessage = result.messages.first
        }
      }

      if !updatedDraftsByID.isEmpty {
        drafts = drafts.map { updatedDraftsByID[$0.id] ?? $0 }
        runPreflight()
        refreshImageWorkbenchReport()
        save()
      } else {
        refreshImageWorkbenchReport()
      }

      if optimizedCount == 0 {
        imageActionMessage = firstMessage ?? "当前 Profile 没有可优化的 SVG 图片。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        imageActionMessage = "已批量优化 \(optimizedCount) 个 SVG 副本，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "批量 SVG 优化失败：\(error.localizedDescription)"
    }
  }

  public func resizeSelectedDraftLargeImages() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    do {
      let result = try imageWorkbenchService.resizeLargeAttachments(
        draft: selectedDraft,
        destinationDirectory: persistence.imageOptimizationDirectoryURL
      )

      if result.optimizedCount > 0 {
        updateDraft(result.draft)
        save()
      }

      refreshImageWorkbenchReport()

      if result.optimizedCount == 0 {
        imageActionMessage = result.messages.first ?? "没有需要缩放的大图。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
        imageActionMessage = "已缩放 \(result.optimizedCount) 张大图，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "图片缩放失败：\(error.localizedDescription)"
    }
  }

  public func resizeVisibleDraftLargeImages() {
    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var resizedCount = 0
    var savedBytes: Int64 = 0
    var firstMessage: String?

    do {
      for draft in visibleDrafts {
        let result = try imageWorkbenchService.resizeLargeAttachments(
          draft: draft,
          destinationDirectory: persistence.imageOptimizationDirectoryURL
        )

        if result.optimizedCount > 0 {
          updatedDraftsByID[draft.id] = result.draft
          resizedCount += result.optimizedCount
          savedBytes += result.savedBytes
        } else if firstMessage == nil {
          firstMessage = result.messages.first
        }
      }

      if !updatedDraftsByID.isEmpty {
        drafts = drafts.map { updatedDraftsByID[$0.id] ?? $0 }
        runPreflight()
        refreshImageWorkbenchReport()
        save()
      } else {
        refreshImageWorkbenchReport()
      }

      if resizedCount == 0 {
        imageActionMessage = firstMessage ?? "当前 Profile 没有需要缩放的大图。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        imageActionMessage = "已批量缩放 \(resizedCount) 张大图，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "批量图片缩放失败：\(error.localizedDescription)"
    }
  }

  public func cropSelectedDraftCoverImageForSocialPreview() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    guard let coverAttachmentID = selectedDraft.coverAttachmentID else {
      imageActionMessage = "请先设置封面图，再裁剪 16:9 封面。"
      return
    }

    do {
      let result = try imageWorkbenchService.cropAttachmentToAspectRatio(
        draft: selectedDraft,
        attachmentID: coverAttachmentID,
        destinationDirectory: persistence.imageOptimizationDirectoryURL,
        aspectWidth: 16,
        aspectHeight: 9
      )

      if result.optimizedCount > 0 {
        updateDraft(result.draft)
        save()
      }

      refreshImageWorkbenchReport()

      if result.optimizedCount == 0 {
        imageActionMessage = result.messages.first ?? "封面图不需要裁剪。"
      } else {
        let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
        imageActionMessage = "已裁剪封面图为 16:9，预计减少 \(saved)。"
      }
    } catch {
      imageActionMessage = "封面图裁剪失败：\(error.localizedDescription)"
    }
  }

  public func makeAttachment(from url: URL, draft: ArticleDraft) -> DraftAttachment {
    let filename = url.lastPathComponent.nilIfEmpty ?? "image-\(UUID().uuidString).jpg"
    let byteSize = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
    let profile = profile(for: draft)
    let repositoryPath = profile.imageRepositoryPath(filename: filename, draft: draft)
    return DraftAttachment(
      originalFilename: filename,
      relativePublishPath: profile.publicImagePath(filename: filename, draft: draft),
      repositoryPath: repositoryPath,
      byteSize: byteSize,
      sourceFilePath: url.path
    )
  }

  public func setSelectedDraftCoverAttachment(_ attachmentID: UUID?) {
    guard var draft = selectedDraft else { return }
    if let attachmentID, !draft.attachments.contains(where: { $0.id == attachmentID }) {
      imageActionMessage = "找不到要设为封面的图片。"
      return
    }
    draft.coverAttachmentID = attachmentID
    draft.updatedAt = Date()
    updateDraft(draft)
    imageActionMessage = attachmentID == nil ? "已清除封面图。" : "已设置封面图。"
  }

  public func attachRepositoryImageToSelectedDraft(repositoryPath: String) {
    guard var draft = selectedDraft else {
      imageActionMessage = "请先选择文章。"
      return
    }
    if draft.attachments.contains(where: { $0.repositoryPath == repositoryPath }) {
      imageActionMessage = "\(repositoryPath) 已在当前文章图片列表中。"
      return
    }

    let profile = profile(for: draft)
    let filename = URL(fileURLWithPath: repositoryPath).lastPathComponent
    let sourceURL = profile.localRepositoryRootURL?.appendingPathComponent(repositoryPath)
    let byteSize = (try? sourceURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    let publicPath: String
    if repositoryPath.hasPrefix(profile.assetRoot + "/") {
      publicPath = "/" + String(repositoryPath.dropFirst(profile.assetRoot.count + 1))
    } else {
      publicPath = profile.publicImagePath(filename: filename, draft: draft)
    }
    let altText = URL(fileURLWithPath: filename)
      .deletingPathExtension()
      .lastPathComponent
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmedForPublishing
    let attachment = DraftAttachment(
      originalFilename: filename,
      relativePublishPath: publicPath,
      repositoryPath: repositoryPath,
      altText: altText,
      byteSize: byteSize,
      sourceFilePath: sourceURL?.path
    )
    draft.attachments.append(attachment)
    draft.updatedAt = Date()
    updateDraft(draft)
    store.selectSection(.images)
    imageActionMessage = "已把 \(repositoryPath) 加入当前文章图片列表。"
    save()
  }
}
