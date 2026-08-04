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
  private var imageReportTask: Task<ImageWorkbenchReport, Error>?
  private var imageReportGeneration: UInt64 = 0
  private var imageReportBaseline: ImageWorkbenchReportInputSignature?
  private var imageReportBaselineRevision: UInt64?
  private var siteSummaryTask: Task<ImageWorkbenchSiteSummary, Error>?
  private var siteSummaryGeneration: UInt64 = 0
  private var siteSummaryBaseline: ImageWorkbenchSiteSummaryInputSignature?
  private var siteSummaryBaselineRevision: UInt64?
  private var lastBatchRetryAction: (@MainActor () -> Void)?

  @Published public private(set) var imageBatchProgress: ImageBatchProgress?
  @Published public private(set) var isImageBatchProcessing = false
  @Published public private(set) var lastBatchFailure: String?
  @Published public private(set) var lastBatchOperation: ImageBatchOperation?
  @Published public private(set) var backgroundImageReport: ImageWorkbenchReport?
  @Published public private(set) var imageReportLoadingDraftID: UUID?
  @Published public private(set) var backgroundSiteSummary: ImageWorkbenchSiteSummary?
  @Published public private(set) var isSiteSummaryLoading = false
  @Published public private(set) var siteSummaryErrorMessage: String?

  init(
    store: WorkbenchStore,
    imageWorkbenchService: SiteImageWorkbenchService,
    persistence: WorkbenchPersistence
  ) {
    self.store = store
    self.imageWorkbenchService = imageWorkbenchService
    self.persistence = persistence
    self.batchProcessor = ImageBatchProcessingActor(service: imageWorkbenchService)
    persistence.pruneUnreferencedImageOptimizationBatches(
      referencedSourceFilePaths: store.drafts.flatMap(\.attachments).compactMap(\.sourceFilePath)
    )
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
    imageActionMessage = CoreL10n.text("正在取消图片处理…")
    imageBatchCancellationToken?.cancel()
    imageBatchTask?.cancel()
  }

  private func startImageBatch(
    _ operation: ImageBatchOperation,
    drafts: [ArticleDraft],
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>] = [:]
  ) {
    guard !isImageBatchProcessing else {
      imageActionMessage = CoreL10n.text("已有图片处理任务正在运行，请先等待或取消。")
      return
    }
    guard !drafts.isEmpty else {
      imageActionMessage = CoreL10n.text("没有可处理的文章。")
      return
    }

    store.flushDraftBodyEditorBuffers()
    let requestedDraftIDs = Set(drafts.map(\.id))
    let currentDrafts = store.drafts.filter { requestedDraftIDs.contains($0.id) }
    guard !currentDrafts.isEmpty else {
      imageActionMessage = CoreL10n.text("没有可处理的文章。")
      return
    }

    let operationID = UUID()
    let cancellationToken = ImageProcessingCancellationToken()
    let batchProcessor = batchProcessor
    let destinationRoot = persistence.imageOptimizationDirectoryURL
    _ = store.recordVersionsBeforeBatchProcessing(draftIDs: Set(currentDrafts.map(\.id)))
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
    lastBatchFailure = nil
    lastBatchOperation = operation
    lastBatchRetryAction = { [weak self] in
      self?.startImageBatch(
        operation,
        drafts: currentDrafts,
        includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
      )
    }
    imageActionMessage = CoreL10n.format("正在%@：0/%d 篇文章。", operation.progressTitle, currentDrafts.count)

    imageBatchTask = Task { [weak self] in
      do {
        let result = try await batchProcessor.process(
          operation: operation,
          drafts: currentDrafts,
          includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID,
          destinationRoot: destinationRoot,
          cancellationToken: cancellationToken,
          progress: { [weak self] progress in
            guard self?.imageBatchOperationID == operationID else { return }
            self?.imageBatchProgress = progress
            self?.imageActionMessage = CoreL10n.format(
              "正在%@：%d/%d 篇文章。",
              progress.operation.progressTitle,
              progress.completedDraftCount,
              progress.totalDraftCount
            )
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
          message: CoreL10n.format("已取消%@，临时文件已清理。", operation.progressTitle),
          failure: nil
        )
      } catch {
        self?.finishImageBatch(
          operationID: operationID,
          message: CoreL10n.format("%@失败：%@", operation.progressTitle, error.localizedDescription),
          failure: error.localizedDescription
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
        message: CoreL10n.format(
          "有 %d 篇文章在图片处理期间被修改，本次结果未应用；请确认编辑内容后重新运行。",
          conflictingDraftIDs.count
        ),
        failure: "有文章在图片处理期间被修改，请确认编辑内容后重新运行。"
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
      persistence.pruneUnreferencedImageOptimizationBatches(
        referencedSourceFilePaths: store.drafts.flatMap(\.attachments).compactMap(\.sourceFilePath)
      )
    } else {
      try? FileManager.default.removeItem(at: result.outputDirectory)
    }
    scheduleImageWorkbenchCachesRefresh(force: true)

    let message: String
    if result.optimizedCount == 0 {
      message = result.firstMessage ?? CoreL10n.format("没有可%@的图片。", operation.progressTitle)
    } else {
      let saved = ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file)
      switch operation {
      case .optimizeJPEG:
        message = CoreL10n.format("已批量生成 %d 个 JPEG 优化副本，预计减少 %@。", result.optimizedCount, saved)
      case .convertWebP:
        message = CoreL10n.format("已批量转换 %d 张 WebP 图片，预计减少 %@。", result.optimizedCount, saved)
      case .optimizeSVG:
        message = CoreL10n.format("已批量优化 %d 个 SVG 副本，预计减少 %@。", result.optimizedCount, saved)
      case .resizeLargeImages:
        message = CoreL10n.format("已批量缩放 %d 张大图，预计减少 %@。", result.optimizedCount, saved)
      case .cropCover16By9:
        message = CoreL10n.format("已裁剪封面图为 16:9，预计减少 %@。", saved)
      }
    }
    finishImageBatch(operationID: imageBatchOperationID, message: message, failure: nil)
  }

  private func finishImageBatch(operationID: UUID?, message: String, failure: String? = nil) {
    guard operationID == imageBatchOperationID else { return }
    imageBatchTask = nil
    imageBatchCancellationToken = nil
    imageBatchOperationID = nil
    imageBatchDraftBaselines = [:]
    imageBatchProgress = nil
    isImageBatchProcessing = false
    lastBatchFailure = failure
    imageActionMessage = message
  }

  public func retryLastBatch() {
    guard !isImageBatchProcessing, let lastBatchRetryAction else {
      imageActionMessage = CoreL10n.text("当前没有可重试的图片处理任务。")
      return
    }
    lastBatchRetryAction()
  }

  public func refreshImageWorkbenchReport() {
    guard let selectedDraft else {
      imageWorkbenchReport = nil
      backgroundImageReport = nil
      imageReportBaseline = nil
      return
    }

    let profile = profile(for: selectedDraft)
    let report = imageWorkbenchService.report(
      draft: selectedDraft,
      profile: profile
    )
    imageWorkbenchReport = report
    backgroundImageReport = report
    imageReportBaseline = ImageWorkbenchReportInputSignature(
      draft: selectedDraft,
      profile: profile
    )
    imageReportBaselineRevision = store.imageWorkbenchInputRevision
  }

  public func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    imageWorkbenchService.report(draft: draft, profile: profile(for: draft))
  }

  public func cachedImageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport? {
    guard imageReportBaseline != nil,
          imageReportBaselineRevision == store.imageWorkbenchInputRevision,
          backgroundImageReport?.draftID == draft.id else {
      return nil
    }
    return backgroundImageReport
  }

  public func isImageWorkbenchReportLoading(for draft: ArticleDraft) -> Bool {
    imageReportLoadingDraftID == draft.id
  }

  public func refreshImageWorkbenchReportInBackground(
    for draft: ArticleDraft,
    force: Bool = false
  ) async {
    // The async operation keeps ImageWorkbenchStore alive. Keep its root owner
    // alive for the same lifetime as well; otherwise the unowned back-reference
    // can become dangling while the file-backed report is suspended.
    let owningStore = store
    let profile = owningStore.profile(for: draft)
    imageReportTask?.cancel()
    imageReportGeneration &+= 1
    let generation = imageReportGeneration
    let inputRevision = owningStore.imageWorkbenchInputRevision
    imageReportLoadingDraftID = draft.id
    owningStore.imageWorkbenchBackgroundStateDidChange()

    let signature = await Task.detached(priority: .utility) {
      ImageWorkbenchReportInputSignature(draft: draft, profile: profile)
    }.value
    guard !Task.isCancelled else {
      if generation == imageReportGeneration {
        imageReportLoadingDraftID = nil
        owningStore.imageWorkbenchBackgroundStateDidChange()
      }
      return
    }
    guard generation == imageReportGeneration else { return }
    if !force,
       imageReportBaseline == signature,
       backgroundImageReport?.draftID == draft.id {
      imageReportBaselineRevision = inputRevision
      imageReportLoadingDraftID = nil
      owningStore.imageWorkbenchBackgroundStateDidChange()
      return
    }

    let service = imageWorkbenchService
    let task = Task {
      try await service.reportAsync(draft: draft, profile: profile)
    }
    imageReportTask = task
    let result = await withTaskCancellationHandler {
      await task.result
    } onCancel: {
      task.cancel()
    }

    guard generation == imageReportGeneration else { return }
    imageReportTask = nil
    imageReportLoadingDraftID = nil

    guard owningStore.imageWorkbenchInputRevision == inputRevision,
          owningStore.drafts.contains(where: { $0.id == draft.id }),
          case .success(let report) = result else {
      owningStore.imageWorkbenchBackgroundStateDidChange()
      return
    }

    imageReportBaseline = signature
    imageReportBaselineRevision = inputRevision
    backgroundImageReport = report
    if owningStore.selectedDraft?.id == draft.id {
      imageWorkbenchReport = report
    }
    owningStore.imageWorkbenchBackgroundStateDidChange()
  }

  public func cachedImageWorkbenchSiteSummary() -> ImageWorkbenchSiteSummary? {
    guard siteSummaryBaseline != nil,
          siteSummaryBaselineRevision == store.imageWorkbenchInputRevision else {
      return nil
    }
    return backgroundSiteSummary
  }

  public func refreshImageWorkbenchSiteSummaryInBackground(force: Bool = false) async {
    // See the per-draft refresh above. The site-summary child task may outlive
    // the view/root that scheduled it, so retain the owner across every await.
    let owningStore = store
    let drafts = owningStore.visibleDrafts
    let profile = owningStore.activeProfile
    siteSummaryTask?.cancel()
    siteSummaryGeneration &+= 1
    let generation = siteSummaryGeneration
    let inputRevision = owningStore.imageWorkbenchInputRevision
    isSiteSummaryLoading = true
    siteSummaryErrorMessage = nil
    owningStore.imageWorkbenchBackgroundStateDidChange()

    let signature = await Task.detached(priority: .utility) {
      ImageWorkbenchSiteSummaryInputSignature(drafts: drafts, profile: profile)
    }.value
    guard !Task.isCancelled else {
      if generation == siteSummaryGeneration {
        isSiteSummaryLoading = false
        owningStore.imageWorkbenchBackgroundStateDidChange()
      }
      return
    }
    guard generation == siteSummaryGeneration else { return }
    if !force,
       siteSummaryBaseline == signature,
       backgroundSiteSummary != nil {
      siteSummaryBaselineRevision = inputRevision
      isSiteSummaryLoading = false
      owningStore.imageWorkbenchBackgroundStateDidChange()
      return
    }

    let service = imageWorkbenchService
    let task = Task {
      try await service.siteSummaryAsync(drafts: drafts, profile: profile)
    }
    siteSummaryTask = task
    let result = await withTaskCancellationHandler {
      await task.result
    } onCancel: {
      task.cancel()
    }

    guard generation == siteSummaryGeneration else { return }
    siteSummaryTask = nil
    isSiteSummaryLoading = false

    guard owningStore.imageWorkbenchInputRevision == inputRevision else {
      owningStore.imageWorkbenchBackgroundStateDidChange()
      return
    }

    switch result {
    case .success(let summary):
      siteSummaryBaseline = signature
      siteSummaryBaselineRevision = inputRevision
      backgroundSiteSummary = summary
      siteSummaryErrorMessage = nil
    case .failure(let error):
      guard !(error is CancellationError) else {
        owningStore.imageWorkbenchBackgroundStateDidChange()
        return
      }
      siteSummaryErrorMessage = error.localizedDescription
    }
    owningStore.imageWorkbenchBackgroundStateDidChange()
  }

  public func refreshImageWorkbenchCachesInBackground(
    for draft: ArticleDraft,
    force: Bool = false
  ) async {
    // async-let children start independently. Retain the owner in the parent
    // task until both have completed so neither child can begin with a dangling
    // unowned back-reference.
    let owningStore = store
    async let reportRefresh: Void = refreshImageWorkbenchReportInBackground(
      for: draft,
      force: force
    )
    async let summaryRefresh: Void = refreshImageWorkbenchSiteSummaryInBackground(force: force)
    _ = await (reportRefresh, summaryRefresh)
    withExtendedLifetime(owningStore) {}
  }

  private func scheduleImageWorkbenchCachesRefresh(force: Bool = false) {
    let draft = selectedDraft
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let draft {
        await refreshImageWorkbenchCachesInBackground(for: draft, force: force)
      } else {
        await refreshImageWorkbenchSiteSummaryInBackground(force: force)
      }
    }
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
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }

    let result = imageWorkbenchService.fillMissingMetadata(draft: selectedDraft)
    let changedCount = result.filledAltTextCount
      + result.filledCaptionCount
      + result.updatedMarkdownReferenceCount

    guard changedCount > 0 else {
      imageActionMessage = CoreL10n.text("没有需要补全的图片元数据。")
      scheduleImageWorkbenchCachesRefresh(force: true)
      return
    }

    updateDraft(result.draft)
    scheduleImageWorkbenchCachesRefresh()
    save()
    imageActionMessage = CoreL10n.format(
      "已补全 %d 个 alt、%d 个 caption，更新 %d 处正文引用。",
      result.filledAltTextCount,
      result.filledCaptionCount,
      result.updatedMarkdownReferenceCount
    )
  }

  public func fillMissingImageMetadataForVisibleDrafts() {
    let selection = Dictionary(
      uniqueKeysWithValues: visibleDrafts.map { draft in
        (draft.id, Set(draft.attachments.map(\.id)))
      }
    )
    fillMissingImageMetadataForVisibleDrafts(includedAttachmentIDsByDraftID: selection)
  }

  public func fillMissingImageMetadataForVisibleDrafts(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var filledAltTextCount = 0
    var filledCaptionCount = 0
    var updatedMarkdownReferenceCount = 0

    for draft in visibleDrafts {
      guard let includedAttachmentIDs = includedAttachmentIDsByDraftID[draft.id],
            !includedAttachmentIDs.isEmpty else { continue }
      let result = imageWorkbenchService.fillMissingMetadata(
        draft: draft,
        includedAttachmentIDs: includedAttachmentIDs
      )
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
      imageActionMessage = CoreL10n.text("当前 Profile 没有需要补全的图片元数据。")
      scheduleImageWorkbenchCachesRefresh(force: true)
      return
    }

    _ = store.recordVersionsBeforeBatchProcessing(draftIDs: Set(updatedDraftsByID.keys))
    drafts = drafts.map { updatedDraftsByID[$0.id] ?? $0 }
    runPreflight()
    scheduleImageWorkbenchCachesRefresh()
    save()
    imageActionMessage = CoreL10n.format(
      "已批量补全 %d 个 alt、%d 个 caption，更新 %d 处正文引用。",
      filledAltTextCount,
      filledCaptionCount,
      updatedMarkdownReferenceCount
    )
  }

  public func optimizeSelectedDraftJPEGImages() {
    guard let selectedDraft else {
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }
    startImageBatch(.optimizeJPEG, drafts: [selectedDraft])
  }

  public func optimizeVisibleDraftJPEGImages() {
    startImageBatch(.optimizeJPEG, drafts: visibleDrafts)
  }

  public func optimizeVisibleDraftJPEGImages(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    startImageBatch(
      .optimizeJPEG,
      drafts: visibleDrafts.filter { includedAttachmentIDsByDraftID[$0.id]?.isEmpty == false },
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func convertSelectedDraftImagesToWebP() {
    guard let selectedDraft else {
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }

    startImageBatch(.convertWebP, drafts: [selectedDraft])
  }

  public func convertVisibleDraftImagesToWebP() {
    startImageBatch(.convertWebP, drafts: visibleDrafts)
  }

  public func convertVisibleDraftImagesToWebP(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    startImageBatch(
      .convertWebP,
      drafts: visibleDrafts.filter { includedAttachmentIDsByDraftID[$0.id]?.isEmpty == false },
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func optimizeSelectedDraftSVGImages() {
    guard let selectedDraft else {
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }

    startImageBatch(.optimizeSVG, drafts: [selectedDraft])
  }

  public func optimizeVisibleDraftSVGImages() {
    startImageBatch(.optimizeSVG, drafts: visibleDrafts)
  }

  public func optimizeVisibleDraftSVGImages(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    startImageBatch(
      .optimizeSVG,
      drafts: visibleDrafts.filter { includedAttachmentIDsByDraftID[$0.id]?.isEmpty == false },
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func resizeSelectedDraftLargeImages() {
    guard let selectedDraft else {
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }

    startImageBatch(.resizeLargeImages, drafts: [selectedDraft])
  }

  public func resizeVisibleDraftLargeImages() {
    startImageBatch(.resizeLargeImages, drafts: visibleDrafts)
  }

  public func resizeVisibleDraftLargeImages(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    startImageBatch(
      .resizeLargeImages,
      drafts: visibleDrafts.filter { includedAttachmentIDsByDraftID[$0.id]?.isEmpty == false },
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
  }

  public func cropSelectedDraftCoverImageForSocialPreview() {
    guard let selectedDraft else {
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }

    guard selectedDraft.coverAttachmentID != nil else {
      imageActionMessage = CoreL10n.text("请先设置封面图，再裁剪 16:9 封面。")
      return
    }

    startImageBatch(.cropCover16By9, drafts: [selectedDraft])
  }

  public func makeAttachment(
    from url: URL,
    draft: ArticleDraft,
    fileStore: ManagedAttachmentFileStore = ManagedAttachmentFileStore()
  ) async throws -> DraftAttachment {
    let attachmentID = UUID()
    let filename = url.lastPathComponent.nilIfEmpty ?? "image-\(UUID().uuidString).jpg"
    let managedURL = try await Task.detached(priority: .userInitiated) {
      try fileStore.storeFile(at: url, attachmentID: attachmentID)
    }.value
    do {
      try Task.checkCancellation()
    } catch {
      fileStore.discardStoredFile(at: managedURL)
      throw error
    }
    let byteSize = (
      (try? managedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        .map(Int64.init)
    ) ?? 0
    let profile = profile(for: draft)
    let repositoryPath = profile.imageRepositoryPath(filename: filename, draft: draft)
    return DraftAttachment(
      id: attachmentID,
      originalFilename: filename,
      relativePublishPath: profile.publicImagePath(filename: filename, draft: draft),
      repositoryPath: repositoryPath,
      byteSize: byteSize,
      sourceFilePath: managedURL.path
    )
  }

  public func setSelectedDraftCoverAttachment(_ attachmentID: UUID?) {
    guard var draft = selectedDraft else { return }
    if let attachmentID, !draft.attachments.contains(where: { $0.id == attachmentID }) {
      imageActionMessage = CoreL10n.text("找不到要设为封面的图片。")
      return
    }
    draft.coverAttachmentID = attachmentID
    draft.updatedAt = Date()
    updateDraft(draft)
    imageActionMessage = attachmentID == nil
      ? CoreL10n.text("已清除封面图。")
      : CoreL10n.text("已设置封面图。")
  }

  public func attachRepositoryImageToSelectedDraft(repositoryPath: String) {
    guard let draftID = selectedDraft?.id else {
      imageActionMessage = CoreL10n.text("请先选择文章。")
      return
    }
    attachRepositoryImage(repositoryPath: repositoryPath, toDraftID: draftID)
  }

  public func attachRepositoryImage(repositoryPath: String, toDraftID draftID: UUID) {
    guard var draft = visibleDrafts.first(where: { $0.id == draftID }) else {
      imageActionMessage = CoreL10n.text("请选择当前站点中的目标文章。")
      return
    }

    let profile = profile(for: draft)
    let location: RepositoryImageAssetLocation
    do {
      location = try RepositoryImageInventoryService().validatedAssetLocation(
        profile: profile,
        repositoryPath: repositoryPath
      )
    } catch {
      imageActionMessage = error.localizedDescription
      return
    }

    if draft.attachments.contains(where: { $0.repositoryPath == location.repositoryPath }) {
      imageActionMessage = CoreL10n.format("%@ 已在目标文章图片列表中。", location.repositoryPath)
      return
    }

    let filename = URL(fileURLWithPath: location.repositoryPath).lastPathComponent
    let sourceURL = URL(fileURLWithPath: location.absoluteFilePath)
    let assetRoot = profile.assetRoot.normalizedRelativePath()
    let publicPath: String
    if location.repositoryPath.hasPrefix(assetRoot + "/") {
      publicPath = "/" + String(location.repositoryPath.dropFirst(assetRoot.count + 1))
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
      repositoryPath: location.repositoryPath,
      altText: altText,
      byteSize: location.byteSize,
      sourceFilePath: sourceURL.path
    )
    draft.attachments.append(attachment)
    draft.updatedAt = Date()
    updateDraft(draft)
    store.selectSection(.images)
    imageActionMessage = CoreL10n.format("已把 %@ 加入目标文章图片列表。", location.repositoryPath)
    save()
  }
}
