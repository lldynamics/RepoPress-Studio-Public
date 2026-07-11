import Combine
import Foundation

@MainActor
public final class ImageWorkbenchStore: ObservableObject {
  private unowned let store: WorkbenchStore
  private let imageWorkbenchService: SiteImageWorkbenchService
  private let persistence: WorkbenchPersistence
  private let batchProcessor: ImageBatchProcessingActor
  private var imageBatchTask: Task<Void, Never>?
  private var imageBatchCancellationToken: ImageProcessingCancellationToken?
  private var imageBatchOperationID: UUID?
  private var imageBatchDraftBaselines: [UUID: DraftOperationBaseline] = [:]

  @Published public private(set) var imageBatchProgress: ImageBatchProgress?
  @Published public private(set) var isImageBatchProcessing = false

  init(
    store: WorkbenchStore,
    imageWorkbenchService: SiteImageWorkbenchService,
    persistence: WorkbenchPersistence
  ) {
    self.store = store
    self.imageWorkbenchService = imageWorkbenchService
    self.persistence = persistence
    self.batchProcessor = ImageBatchProcessingActor(service: imageWorkbenchService)
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

  public func cancelImageBatchProcessing() {
    guard isImageBatchProcessing else { return }
    imageActionMessage = "正在取消图片处理…"
    imageBatchCancellationToken?.cancel()
    imageBatchTask?.cancel()
  }

  private func startImageBatch(_ operation: ImageBatchOperation, drafts: [ArticleDraft]) {
    guard !isImageBatchProcessing else {
      imageActionMessage = "已有图片处理任务正在运行，请先等待或取消。"
      return
    }
    guard !drafts.isEmpty else {
      imageActionMessage = "没有可处理的文章。"
      return
    }

    store.flushDraftBodyEditorBuffers()
    let requestedDraftIDs = Set(drafts.map(\.id))
    let currentDrafts = store.drafts.filter { requestedDraftIDs.contains($0.id) }
    guard !currentDrafts.isEmpty else {
      imageActionMessage = "没有可处理的文章。"
      return
    }

    let operationID = UUID()
    let cancellationToken = ImageProcessingCancellationToken()
    let batchProcessor = batchProcessor
    let destinationRoot = persistence.imageOptimizationDirectoryURL
    imageBatchOperationID = operationID
    imageBatchDraftBaselines = Dictionary(
      uniqueKeysWithValues: currentDrafts.compactMap { draft in
        store.draftOperationBaseline(for: draft.id).map { (draft.id, $0) }
      }
    )
    imageBatchCancellationToken = cancellationToken
    imageBatchProgress = ImageBatchProgress(
      operation: operation,
      completedDraftCount: 0,
      totalDraftCount: currentDrafts.count
    )
    isImageBatchProcessing = true
    imageActionMessage = "正在\(operation.progressTitle)：0/\(currentDrafts.count) 篇文章。"

    imageBatchTask = Task { [weak self] in
      do {
        let result = try await batchProcessor.process(
          operation: operation,
          drafts: currentDrafts,
          destinationRoot: destinationRoot,
          cancellationToken: cancellationToken,
          progress: { [weak self] progress in
            guard self?.imageBatchOperationID == operationID else { return }
            self?.imageBatchProgress = progress
            self?.imageActionMessage = "正在\(progress.operation.progressTitle)：\(progress.completedDraftCount)/\(progress.totalDraftCount) 篇文章。"
          }
        )
        guard self?.imageBatchOperationID == operationID else {
          try? FileManager.default.removeItem(at: result.outputDirectory)
          return
        }
        self?.applyImageBatch(result, operation: operation)
      } catch is CancellationError {
        self?.finishImageBatch(
          operationID: operationID,
          message: "已取消\(operation.progressTitle)，临时文件已清理。"
        )
      } catch {
        self?.finishImageBatch(
          operationID: operationID,
          message: "\(operation.progressTitle)失败：\(error.localizedDescription)"
        )
      }
    }
  }

  private func applyImageBatch(_ result: ImageBatchProcessingResult, operation: ImageBatchOperation) {
    guard imageBatchOperationID != nil else {
      try? FileManager.default.removeItem(at: result.outputDirectory)
      return
    }

    let conflictingDraftIDs = result.updatedDraftsByID.keys.filter { draftID in
      guard let baseline = imageBatchDraftBaselines[draftID] else { return true }
      return !store.draftStillMatchesOperationBaseline(baseline)
    }
    guard conflictingDraftIDs.isEmpty else {
      try? FileManager.default.removeItem(at: result.outputDirectory)
      finishImageBatch(
        operationID: imageBatchOperationID,
        message: "有 \(conflictingDraftIDs.count) 篇文章在图片处理期间被修改，本次结果未应用；请确认编辑内容后重新运行。"
      )
      return
    }

    if !result.updatedDraftsByID.isEmpty {
      for updatedDraft in result.updatedDraftsByID.values {
        store.updateDraft(updatedDraft)
      }
      store.invalidateDraftDerivedCaches()
      runPreflight()
      save()
    } else {
      try? FileManager.default.removeItem(at: result.outputDirectory)
    }
    refreshImageWorkbenchReport()

    let message: String
    if result.optimizedCount == 0 {
      message = result.firstMessage ?? "没有可\(operation.progressTitle)的图片。"
    } else {
      let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
      switch operation {
      case .optimizeJPEG:
        message = "已批量生成 \(result.optimizedCount) 个 JPEG 优化副本，预计减少 \(saved)。"
      case .convertWebP:
        message = "已批量转换 \(result.optimizedCount) 张 WebP 图片，预计减少 \(saved)。"
      case .optimizeSVG:
        message = "已批量优化 \(result.optimizedCount) 个 SVG 副本，预计减少 \(saved)。"
      case .resizeLargeImages:
        message = "已批量缩放 \(result.optimizedCount) 张大图，预计减少 \(saved)。"
      case .cropCover16By9:
        message = "已裁剪封面图为 16:9，预计减少 \(saved)。"
      }
    }
    finishImageBatch(operationID: imageBatchOperationID, message: message)
  }

  private func finishImageBatch(operationID: UUID?, message: String) {
    guard operationID == imageBatchOperationID else { return }
    imageBatchTask = nil
    imageBatchCancellationToken = nil
    imageBatchOperationID = nil
    imageBatchDraftBaselines = [:]
    imageBatchProgress = nil
    isImageBatchProcessing = false
    imageActionMessage = message
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
    startImageBatch(.optimizeJPEG, drafts: [selectedDraft])
  }

  public func optimizeVisibleDraftJPEGImages() {
    startImageBatch(.optimizeJPEG, drafts: visibleDrafts)
  }

  public func convertSelectedDraftImagesToWebP() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    startImageBatch(.convertWebP, drafts: [selectedDraft])
  }

  public func convertVisibleDraftImagesToWebP() {
    startImageBatch(.convertWebP, drafts: visibleDrafts)
  }

  public func optimizeSelectedDraftSVGImages() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    startImageBatch(.optimizeSVG, drafts: [selectedDraft])
  }

  public func optimizeVisibleDraftSVGImages() {
    startImageBatch(.optimizeSVG, drafts: visibleDrafts)
  }

  public func resizeSelectedDraftLargeImages() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    startImageBatch(.resizeLargeImages, drafts: [selectedDraft])
  }

  public func resizeVisibleDraftLargeImages() {
    startImageBatch(.resizeLargeImages, drafts: visibleDrafts)
  }

  public func cropSelectedDraftCoverImageForSocialPreview() {
    guard let selectedDraft else {
      imageActionMessage = "请先选择一篇文章。"
      return
    }

    guard selectedDraft.coverAttachmentID != nil else {
      imageActionMessage = "请先设置封面图，再裁剪 16:9 封面。"
      return
    }

    startImageBatch(.cropCover16By9, drafts: [selectedDraft])
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
