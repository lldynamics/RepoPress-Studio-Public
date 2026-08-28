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
  private var imageReportTasks: [UUID: Task<ImageWorkbenchReport, Error>] = [:]
  private var imageReportGenerations: [UUID: UInt64] = [:]
  private var imageReportBaselines: [UUID: ImageWorkbenchReportInputSignature] = [:]
  private var backgroundImageReports: [UUID: ImageWorkbenchReport] = [:]
  private var imageReportLoadingDraftIDs = Set<UUID>()
  private var siteSummaryTask: Task<ImageWorkbenchSiteSummary, Error>?
  private var siteSummaryGeneration: UInt64 = 0
  private var siteSummaryBaseline: ImageWorkbenchSiteSummaryInputSignature?
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
      case .removePrivacyMetadata:
        message = CoreL10n.format("已为 %d 张图片生成隐私清理副本。", result.optimizedCount)
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

  private func currentImageReportSignature(for draftID: UUID) -> ImageWorkbenchReportInputSignature? {
    guard let currentDraft = store.drafts.first(where: { $0.id == draftID }) else {
      return nil
    }
    return ImageWorkbenchReportInputSignature(
      draft: currentDraft,
      profile: profile(for: currentDraft)
    )
  }

  private func cachedImageWorkbenchReport(for draftID: UUID) -> ImageWorkbenchReport? {
    guard let baseline = imageReportBaselines[draftID],
          let report = backgroundImageReports[draftID],
          report.draftID == draftID,
          let currentSignature = currentImageReportSignature(for: draftID),
          baseline == currentSignature else {
      return nil
    }
    return report
  }

  /// Keeps the legacy fields as a projection of the selected draft only.
  /// Per-draft reports, baselines, and loading state remain available to the
  /// explicit draft-scoped APIs without changing the existing facade surface.
  private func projectSelectedImageReport() {
    guard let selectedDraftID = store.selectedDraftID else {
      imageWorkbenchReport = nil
      backgroundImageReport = nil
      imageReportLoadingDraftID = nil
      return
    }

    backgroundImageReport = cachedImageWorkbenchReport(for: selectedDraftID)
    imageWorkbenchReport = backgroundImageReport
    imageReportLoadingDraftID = imageReportLoadingDraftIDs.contains(selectedDraftID)
      ? selectedDraftID
      : nil
  }

  /// Reprojects the compatibility fields after the active editor changes.
  /// The keyed report cache remains the source of truth.
  func restoreImageWorkbenchReportProjectionForCurrentSelection() {
    projectSelectedImageReport()
  }

  /// Drops report state for drafts that are no longer part of the workspace.
  ///
  /// Draft-scoped refreshes can outlive the mutation that removes their draft.
  /// Cancelling the task is useful for the file-backed work itself, while
  /// removing its generation makes a late completion unable to install a
  /// result if the underlying operation does not observe cancellation.
  func reconcileDraftReportState(validDraftIDs: Set<UUID>) {
    let trackedDraftIDs = Set(imageReportTasks.keys)
      .union(imageReportGenerations.keys)
      .union(imageReportBaselines.keys)
      .union(backgroundImageReports.keys)
      .union(imageReportLoadingDraftIDs)
    let removedDraftIDs = trackedDraftIDs.subtracting(validDraftIDs)
    guard !removedDraftIDs.isEmpty else { return }

    for draftID in removedDraftIDs {
      imageReportTasks[draftID]?.cancel()
      imageReportTasks[draftID] = nil
      imageReportGenerations[draftID] = nil
      imageReportBaselines[draftID] = nil
      backgroundImageReports[draftID] = nil
      imageReportLoadingDraftIDs.remove(draftID)
    }

    projectSelectedImageReport()
    store.imageWorkbenchBackgroundStateDidChange()
  }

  private func finishImageReportGeneration(
    for draftID: UUID,
    generation: UInt64
  ) -> Bool {
    guard imageReportGenerations[draftID] == generation else { return false }
    imageReportTasks[draftID] = nil
    imageReportLoadingDraftIDs.remove(draftID)
    projectSelectedImageReport()
    store.imageWorkbenchBackgroundStateDidChange()
    return true
  }

  public func refreshImageWorkbenchReport() {
    guard let selectedDraft else {
      projectSelectedImageReport()
      return
    }

    let draftID = selectedDraft.id
    imageReportTasks[draftID]?.cancel()
    imageReportTasks[draftID] = nil
    imageReportGenerations[draftID, default: 0] &+= 1
    imageReportLoadingDraftIDs.remove(draftID)
    let profile = profile(for: selectedDraft)
    let report = imageWorkbenchService.report(
      draft: selectedDraft,
      profile: profile
    )
    backgroundImageReports[draftID] = report
    imageReportBaselines[draftID] = ImageWorkbenchReportInputSignature(
      draft: selectedDraft,
      profile: profile
    )
    projectSelectedImageReport()
  }

  public func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    imageWorkbenchService.report(draft: draft, profile: profile(for: draft))
  }

  public func cachedImageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport? {
    cachedImageWorkbenchReport(for: draft.id)
  }

  public func isImageWorkbenchReportLoading(for draft: ArticleDraft) -> Bool {
    imageReportLoadingDraftIDs.contains(draft.id)
  }

  public func refreshImageWorkbenchReportInBackground(
    for draft: ArticleDraft,
    force: Bool = false
  ) async {
    // The async operation keeps ImageWorkbenchStore alive. Keep its root owner
    // alive for the same lifetime as well; otherwise the unowned back-reference
    // can become dangling while the file-backed report is suspended.
    let owningStore = store
    let draftID = draft.id
    let profile = owningStore.profile(for: draft)
    imageReportTasks[draftID]?.cancel()
    let generation = (imageReportGenerations[draftID] ?? 0) &+ 1
    imageReportGenerations[draftID] = generation
    imageReportLoadingDraftIDs.insert(draftID)
    projectSelectedImageReport()
    owningStore.imageWorkbenchBackgroundStateDidChange()

    let signature = await Task.detached(priority: .utility) {
      ImageWorkbenchReportInputSignature(draft: draft, profile: profile)
    }.value
    guard !Task.isCancelled else {
      _ = finishImageReportGeneration(for: draftID, generation: generation)
      return
    }
    guard imageReportGenerations[draftID] == generation else { return }
    if !force,
       imageReportBaselines[draftID] == signature,
       cachedImageWorkbenchReport(for: draftID) != nil {
      _ = finishImageReportGeneration(for: draftID, generation: generation)
      return
    }

    let service = imageWorkbenchService
    let task = Task {
      try await service.reportAsync(draft: draft, profile: profile)
    }
    imageReportTasks[draftID] = task
    let result = await withTaskCancellationHandler {
      await task.result
    } onCancel: {
      task.cancel()
    }

    guard imageReportGenerations[draftID] == generation else { return }
    imageReportTasks[draftID] = nil
    imageReportLoadingDraftIDs.remove(draftID)

    guard let currentDraft = owningStore.drafts.first(where: { $0.id == draft.id }),
          ImageWorkbenchReportInputSignature(
            draft: currentDraft,
            profile: owningStore.profile(for: currentDraft)
          ) == signature,
          case .success(let report) = result,
          report.draftID == draftID else {
      projectSelectedImageReport()
      owningStore.imageWorkbenchBackgroundStateDidChange()
      return
    }

    imageReportBaselines[draftID] = signature
    backgroundImageReports[draftID] = report
    projectSelectedImageReport()
    owningStore.imageWorkbenchBackgroundStateDidChange()
  }

  public func cachedImageWorkbenchSiteSummary() -> ImageWorkbenchSiteSummary? {
    guard let baseline = siteSummaryBaseline,
          let summary = backgroundSiteSummary,
          baseline == ImageWorkbenchSiteSummaryInputSignature(
            drafts: visibleDrafts,
            profile: store.activeProfile
          ) else {
      return nil
    }
    return summary
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

    guard ImageWorkbenchSiteSummaryInputSignature(
      drafts: owningStore.visibleDrafts,
      profile: owningStore.activeProfile
    ) == signature else {
      owningStore.imageWorkbenchBackgroundStateDidChange()
      return
    }

    switch result {
    case .success(let summary):
      siteSummaryBaseline = signature
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
    drafts = drafts.map { current in
      guard var updated = updatedDraftsByID[current.id] else { return current }
      updated.markUpdated(replacing: current)
      return updated
    }
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

  public func sanitizeSelectedDraftImagePrivacy() {
    guard let selectedDraft else {
      imageActionMessage = CoreL10n.text("请先选择一篇文章。")
      return
    }
    startImageBatch(.removePrivacyMetadata, drafts: [selectedDraft])
  }

  public func sanitizeVisibleDraftImagePrivacy() {
    startImageBatch(.removePrivacyMetadata, drafts: visibleDrafts)
  }

  public func sanitizeVisibleDraftImagePrivacy(
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>]
  ) {
    startImageBatch(
      .removePrivacyMetadata,
      drafts: visibleDrafts.filter { includedAttachmentIDsByDraftID[$0.id]?.isEmpty == false },
      includedAttachmentIDsByDraftID: includedAttachmentIDsByDraftID
    )
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
      try fileStore.discardStoredFile(at: managedURL)
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
