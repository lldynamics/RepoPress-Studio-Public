import AppKit
import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

struct ImageWorkbenchView: View {
  let store: WorkbenchStore
  @Environment(\.workspaceWindowID) var workspaceWindowID
  @Binding var stage: ImageWorkbenchContextStage
  @ObservedObject var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade

  @State var pendingBatchPreview: ImageBatchOperationPreview?
  @ObservedObject var session: RepositoryImageBrowserSession
  let preferredDraftID: UUID?
  @State var activeRepositoryInventoryTaskID: UUID?
  @State var isPreparingSelection = false

  init(
    store: WorkbenchStore, stage: Binding<ImageWorkbenchContextStage>,
    session: RepositoryImageBrowserSession, preferredDraftID: UUID?
  ) {
    self.store = store
    _stage = stage
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
    self.session = session
    self.preferredDraftID = preferredDraftID
  }

  var body: some View {
    VStack(spacing: 0) {
      if stage == .resources, session.resourceMode == .repository {
        if imageWorkbench.actionMessage != nil || imageWorkbench.batchProgress != nil {
          batchStatus.padding(12)
        }
        RepositoryImageBrowserView(
          session: session, isWorking: imageWorkbench.isProcessingBatch || isPreparingSelection,
          onRefresh: refreshAll, onProcess: presentSelectionPreview,
          onOpenRepositorySettings: { store.selectSection(.sync) }
        )
        .accessibilityIdentifier("image-workbench-resources")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            header
            batchStatus
            stageContent
          }
          .workbenchOperationalPageLayout()
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片工作台")
    .accessibilityIdentifier("image-workbench")
    .onAppear {
      normalizeRepositoryTargetDraft()
      applyAssetResourceManagerNavigationRequest()
    }
    .onChange(of: store.activeProfile.id) { _, _ in
      normalizeRepositoryTargetDraft()
      applyAssetResourceManagerNavigationRequest()
    }
    .onChange(of: imageWorkbench.assetResourceManagerNavigationRequest?.id) { _, _ in
      applyAssetResourceManagerNavigationRequest()
    }
    .onChange(of: store.visibleDrafts.map(\.id)) { _, _ in
      normalizeRepositoryTargetDraft()
    }
    .task(id: refreshInput) {
      await store.refreshImageWorkbenchSiteSummaryInBackground()
    }
    .task(id: repositoryInventoryRefreshInput) {
      await refreshRepositoryInventory()
    }
    .sheet(item: $pendingBatchPreview) { preview in
      ImageBatchOperationPreviewView(
        preview: preview,
        cancel: { pendingBatchPreview = nil },
        confirm: { selection in
          pendingBatchPreview = nil
          confirmBatchOperation(preview, selection: selection)
        }
      )
    }
  }

  @ViewBuilder
  var stageContent: some View {
    switch stage {
    case .overview:
      VStack(alignment: .leading, spacing: 16) {
        if let summary = store.cachedImageWorkbenchSiteSummary {
          overview(summary)
          batchActions(summary)
        } else {
          siteSummaryState
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("image-workbench-overview")

    case .resources:
      resourceWorkspace
    }
  }

  private var resourceWorkspace: some View {
    AssetResourceManagerView(store: store)
      .accessibilityIdentifier("image-workbench-resources")
  }

  @ViewBuilder
  private var siteSummaryState: some View {
    if let errorMessage = imageWorkbench.siteSummaryErrorMessage,
      !imageWorkbench.isSiteSummaryLoading
    {
      failureCard(errorMessage)
    } else {
      loadingCard
    }
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        headerIntroduction
        Spacer(minLength: 12)
        headerActions
      }
      VStack(alignment: .leading, spacing: 12) {
        headerIntroduction
        headerActions
      }
    }
  }

  private var headerIntroduction: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("图片工作台")
        .font(.workbenchPageTitle)
      Text(stageDescription)
        .font(.workbenchPageSubtitle)
        .foregroundStyle(.secondary)
    }
  }

  var stageDescription: LocalizedStringKey {
    switch stage {
    case .overview:
      return "管理站点图片资源，并在预览影响范围后执行批量处理。"
    case .resources:
      return session.resourceMode.description
    }
  }

  private var headerActions: some View {
    HStack(spacing: 8) {
      Button {
        openRepositoryImageDirectory()
      } label: {
        Label("打开图片目录", systemImage: "folder")
      }
      .buttonStyle(.bordered)
      .disabled(session.inventory == nil)
      .accessibilityIdentifier("image-workbench-open-folder")

      Button {
        openWritingForImageInsertion()
      } label: {
        Label(
          store.visibleDrafts.isEmpty
            ? String(localized: "新建文章")
            : String(localized: "前往写作"),
          systemImage: store.visibleDrafts.isEmpty ? "plus" : "square.and.pencil"
        )
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("image-workbench-open-writing")

      Button {
        stage = .resources
        session.resourceMode = .manager
      } label: {
        Label("资源管理", systemImage: "archivebox")
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("打开资源管理大总管")
      .accessibilityIdentifier("image-workbench-open-asset-manager")

      Button(action: refreshAll) {
        Label("重新扫描", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
      .disabled(imageWorkbench.isSiteSummaryLoading || session.isLoading)
      .accessibilityLabel("重新扫描文章图片和仓库图片")
      .accessibilityIdentifier("image-workbench-refresh")
    }
    .controlSize(.regular)
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private var batchStatus: some View {
    if let message = imageWorkbench.actionMessage {
      Label(message, systemImage: "info.circle")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    if let progress = imageWorkbench.batchProgress {
      HStack(spacing: 10) {
        ProgressView(value: progress.fractionCompleted)
          .frame(maxWidth: 260)
        Text(progress.operation.progressTitle)
        Text("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") {
          imageWorkbench.cancelBatchProcessing()
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("全站图片处理进度")
      .accessibilityValue("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
    }

  }

  private func overview(_ summary: ImageWorkbenchSiteSummary) -> some View {
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("当前站点")
            .font(.headline)
          Text(store.activeProfile.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(ByteCountFormatter.string(fromByteCount: summary.totalByteSize, countStyle: .file))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
        MetricTile(title: "图片资源", value: "\(summary.imageCount)", systemImage: "photo.on.rectangle")
        MetricTile(
          title: "可压缩 JPEG", value: "\(summary.optimizableJPEGCount)",
          systemImage: "arrow.down.forward")
        MetricTile(
          title: "可转 WebP", value: "\(summary.webPConvertibleCount)",
          systemImage: "arrow.triangle.2.circlepath")
        MetricTile(
          title: "可缩放图片", value: "\(summary.resizableImageCount)",
          systemImage: "arrow.up.left.and.arrow.down.right")
        MetricTile(
          title: "隐私风险", value: "\(summary.sensitiveMetadataCount)", systemImage: "hand.raised")
        MetricTile(
          title: "元数据干净", value: "\(summary.cleanMetadataCount)", systemImage: "checkmark.shield")
        if summary.unverifiedMetadataCount > 0 {
          MetricTile(
            title: "无法验证", value: "\(summary.unverifiedMetadataCount)",
            systemImage: "questionmark.diamond")
        }
      }

    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片工作台概览")
  }

  private func batchActions(_ summary: ImageWorkbenchSiteSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("批量处理")
          .font(.workbenchSectionTitle)
        Text("这些操作只处理图片资源；点击后会先预览影响的文章和图片，不会直接改动文件。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
        ForEach(ImageWorkbenchBatchAction.allActions) { action in
          batchActionButton(action, summary: summary)
        }
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片批量处理")
    .accessibilityIdentifier("image-workbench-actions")
  }

  private func batchActionButton(
    _ action: ImageWorkbenchBatchAction,
    summary: ImageWorkbenchSiteSummary
  ) -> some View {
    let count = action.targetCount(in: summary)
    return Button {
      presentBatchPreview(action, summary: summary)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: action.systemImage)
          .font(.title3)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(action.title)
            .font(.workbenchCardTitle)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Text(action.shortDescription)
            .font(.workbenchSupporting)
            .foregroundStyle(count == 0 ? Color.primary.opacity(0.68) : Color.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 6)
        Text("\(count)")
          .font(.callout.monospacedDigit().weight(.semibold))
      }
      .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
    }
    .buttonStyle(ImageWorkbenchBatchCardStyle(isAvailable: count > 0))
    .disabled(count == 0 || imageWorkbench.isProcessingBatch)
    .help(count == 0 ? String(localized: "当前没有符合此操作的图片。") : action.shortDescription)
    .accessibilityLabel(action.title)
    .accessibilityValue(String(format: String(localized: "%d 张图片"), count))
    .accessibilityIdentifier(action.accessibilityIdentifier)
  }

  private var loadingCard: some View {
    WorkbenchStateView(
      presentation: WorkbenchStatePresentation(
        kind: .loading(detail: String(localized: "正在扫描图片资源…"))
      )
    )
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func failureCard(_ message: String) -> some View {
    WorkbenchStateView(
      presentation: WorkbenchStatePresentation(kind: .failure(reason: message)),
      actions: WorkbenchStateActions(
        primary: WorkbenchStateAction(
          title: "重新扫描",
          systemImage: "arrow.clockwise",
          action: refreshAll
        )
      )
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

}

extension ImageWorkbenchView {
  var refreshInput: UInt64 {
    store.imageWorkbenchInputRevision
  }

  var repositoryInventoryRefreshInput: RepositoryInventoryRefreshInput {
    RepositoryInventoryRefreshInput(
      requestID: session.refreshRequestID,
      imageRevision: store.imageWorkbenchInputRevision,
      profileID: store.activeProfile.id,
      repositoryRootPath: store.activeProfile.localRepositoryRootPath,
      assetRoot: store.activeProfile.assetRoot,
      stage: stage,
      resourceMode: session.resourceMode
    )
  }

  func presentBatchPreview(
    _ action: ImageWorkbenchBatchAction,
    summary: ImageWorkbenchSiteSummary,
    selectedPaths: Set<String>? = nil
  ) {
    let affectedItems: [ImageBatchAffectedItem] = summary.draftSummaries.flatMap { draftSummary in
      draftSummary.items.compactMap { item -> ImageBatchAffectedItem? in
        guard action.includes(item), selectedPaths?.contains(item.repositoryPath) != false else {
          return nil
        }
        return ImageBatchAffectedItem(
          draftID: draftSummary.draftID,
          draftTitle: draftSummary.draftTitle.nilIfEmpty ?? String(localized: "未命名文章"),
          item: item
        )
      }
    }
    guard !affectedItems.isEmpty else {
      imageWorkbench.setActionMessage(String(localized: "所选图片没有符合此操作的文章附件。未登记图片可先加入文章。"))
      return
    }
    pendingBatchPreview = ImageBatchOperationPreview(
      action: action,
      affectedItems: affectedItems,
      context: ImageBatchPreviewContext(store: store),
      excludedFileCount: selectedPaths.map {
        $0.subtracting(Set(affectedItems.map(\.item.repositoryPath))).count
      } ?? 0
    )
  }

  func presentSelectionPreview(_ action: ImageWorkbenchBatchAction) {
    guard !isPreparingSelection, !imageWorkbench.isProcessingBatch,
      session.matches(store.activeProfile)
    else { return }
    let paths = session.selectedPaths
    let source = RepositoryImageInventorySource(store.activeProfile)
    isPreparingSelection = true
    Task { @MainActor in
      defer { isPreparingSelection = false }
      await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
      guard source == RepositoryImageInventorySource(store.activeProfile),
        let summary = store.cachedImageWorkbenchSiteSummary
      else { return }
      presentBatchPreview(action, summary: summary, selectedPaths: paths)
    }
  }

  func confirmBatchOperation(_ preview: ImageBatchOperationPreview, selection: [UUID: Set<UUID>]) {
    for draftID in selection.keys { store.flushDraftBodyEditorBuffer(for: draftID) }
    guard preview.context?.matches(store) == true,
      ImageBatchSelectionValidation.isValid(
        selection, affectedItems: preview.affectedItems,
        drafts: store.visibleDrafts)
    else {
      imageWorkbench.setActionMessage(String(localized: "图片或文章在预览后已变化，请重新预览处理范围。"))
      return
    }
    runBatchOperation(preview.action, selection: selection)
  }

  func runBatchOperation(
    _ action: ImageWorkbenchBatchAction,
    selection: [UUID: Set<UUID>]
  ) {
    switch action {
    case .fillMetadata:
      imageWorkbench.fillMissingMetadataForVisibleDrafts(
        includedAttachmentIDsByDraftID: selection
      )
    case .file(let operation):
      switch operation {
      case .optimizeJPEG:
        imageWorkbench.optimizeVisibleDraftJPEGImages(
          includedAttachmentIDsByDraftID: selection
        )
      case .convertWebP:
        imageWorkbench.convertVisibleDraftImagesToWebP(
          includedAttachmentIDsByDraftID: selection
        )
      case .optimizeSVG:
        imageWorkbench.optimizeVisibleDraftSVGImages(
          includedAttachmentIDsByDraftID: selection
        )
      case .resizeLargeImages:
        imageWorkbench.resizeVisibleDraftLargeImages(
          includedAttachmentIDsByDraftID: selection
        )
      case .cropCover16By9:
        break
      case .removePrivacyMetadata:
        imageWorkbench.sanitizeVisibleDraftImagePrivacy(
          includedAttachmentIDsByDraftID: selection
        )
      }
    }
  }

  func refreshAll() {
    session.refreshRequestID = UUID()
    Task { @MainActor in
      await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
    }
  }

  func refreshRepositoryInventory() async {
    let profile = store.activeProfile
    session.prepare(for: profile, preferredDraftID: preferredDraftID)
    normalizeRepositoryTargetDraft()
    let source = RepositoryImageInventorySource(profile)
    let drafts = store.visibleDrafts
    let taskID = UUID()
    activeRepositoryInventoryTaskID = taskID
    session.isLoading = true
    session.errorMessage = nil
    defer {
      if activeRepositoryInventoryTaskID == taskID { session.isLoading = false }
    }
    do {
      try await Task.sleep(for: .milliseconds(200))
      let inventory = try await RepositoryImageInventoryService().inventoryAsync(
        drafts: drafts, profile: profile
      )
      try Task.checkCancellation()
      guard source == RepositoryImageInventorySource(store.activeProfile),
        activeRepositoryInventoryTaskID == taskID
      else { return }
      session.apply(inventory)
    } catch is CancellationError {
      return
    } catch {
      guard source == RepositoryImageInventorySource(store.activeProfile),
        activeRepositoryInventoryTaskID == taskID
      else { return }
      session.errorMessage = error.localizedDescription
    }
  }

  func openRepositoryImageDirectory() {
    guard let inventory = session.inventory,
      inventory.profileID == store.activeProfile.id
    else { return }
    let directoryURL = URL(fileURLWithPath: inventory.repositoryRootPath, isDirectory: true)
      .appendingPathComponent(inventory.assetRootPath, isDirectory: true)
    NSWorkspace.shared.open(directoryURL)
  }

  func openWritingForImageInsertion() {
    if store.visibleDrafts.isEmpty {
      store.createDraft()
      return
    }
    store.setDraftListContentScope(.currentSite)
    if let targetDraftID = session.targetDraftID {
      _ = store.focusDraft(targetDraftID, section: .writing)
    } else {
      store.selectSection(.writing)
    }
  }

  func normalizeRepositoryTargetDraft() {
    let drafts = store.visibleDrafts
    if let targetDraftID = session.targetDraftID,
      drafts.contains(where: { $0.id == targetDraftID })
    {
      return
    }
    if let selectedDraftID = preferredDraftID,
      drafts.contains(where: { $0.id == selectedDraftID })
    {
      session.targetDraftID = selectedDraftID
    } else {
      session.targetDraftID = drafts.first?.id
    }
  }

  func applyAssetResourceManagerNavigationRequest() {
    guard let workspaceWindowID,
      let request = imageWorkbench.assetResourceManagerNavigationRequest,
      ImageWorkbenchResourceNavigationPolicy.destination(
        for: request,
        activeProfileID: store.activeProfile.id,
        windowID: workspaceWindowID
      ) == .assetResourceManager
    else {
      return
    }
    stage = .resources
    session.resourceMode = .manager
    imageWorkbench.consumeAssetResourceManagerNavigationRequest(request, from: workspaceWindowID)
  }

  func openDraft(_ draftID: UUID) {
    _ = store.focusDraft(draftID, section: .writing)
  }
}
