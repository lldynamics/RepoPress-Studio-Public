import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct ImageWorkbenchView: View {
  let store: WorkbenchStore
  @Binding private var stage: ImageWorkbenchContextStage
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade

  @State private var pendingBatchPreview: ImageBatchOperationPreview?
  @State private var repositoryInventory: RepositoryImageInventory?
  @State private var repositoryInventoryErrorMessage: String?
  @State private var isRepositoryInventoryLoading = false
  @State private var selectedRepositoryPath: String?
  @State private var repositoryTargetDraftID: UUID?
  @State private var repositoryRefreshRequestID = UUID()
  @State private var activeRepositoryInventoryTaskID: UUID?
  @State private var resourceMode: ImageWorkbenchResourceMode = .repository

  init(store: WorkbenchStore, stage: Binding<ImageWorkbenchContextStage>) {
    self.store = store
    _stage = stage
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        batchStatus
        stageContent
      }
      .workbenchOperationalPageLayout()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片工作台")
    .accessibilityIdentifier("image-workbench")
    .onAppear {
      normalizeRepositoryTargetDraft()
    }
    .onChange(of: store.activeProfile.id) { _, _ in
      repositoryInventory = nil
      selectedRepositoryPath = nil
      normalizeRepositoryTargetDraft()
    }
    .onChange(of: store.visibleDrafts.map(\.id)) { _, _ in
      normalizeRepositoryTargetDraft()
    }
    .task(id: refreshInput) {
      await store.refreshImageWorkbenchSiteSummaryInBackground()
    }
    .task(id: repositoryInventoryRefreshInput) {
      guard stage == .resources, resourceMode == .repository else { return }
      await refreshRepositoryInventory()
    }
    .sheet(item: $pendingBatchPreview) { preview in
      ImageBatchOperationPreviewView(
        preview: preview,
        cancel: { pendingBatchPreview = nil },
        confirm: { selection in
          pendingBatchPreview = nil
          runBatchOperation(preview.action, selection: selection)
        }
      )
    }
  }

  @ViewBuilder
  private var stageContent: some View {
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
    VStack(alignment: .leading, spacing: 16) {
      Picker("图片资源功能", selection: $resourceMode) {
        ForEach(ImageWorkbenchResourceMode.allCases) { mode in
          Label(mode.title, systemImage: mode.systemImage)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 360)
      .accessibilityLabel("图片资源功能")
      .accessibilityValue(resourceMode.accessibilityTitle)
      .accessibilityIdentifier("image-resource-mode-picker")

      switch resourceMode {
      case .repository:
        RepositoryImageBrowserView(
          inventory: repositoryInventory,
          isLoading: isRepositoryInventoryLoading,
          errorMessage: repositoryInventoryErrorMessage,
          targetDrafts: store.visibleDrafts,
          targetDraftID: $repositoryTargetDraftID,
          selectedRepositoryPath: $selectedRepositoryPath,
          onAttachToSelectedDraft: attachRepositoryImage,
          onOpenReferencedDraft: openDraft,
          onOpenRepositorySettings: { store.selectSection(.sync) }
        )
      case .manager:
        AssetResourceManagerView(store: store)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("image-workbench-resources")
  }

  @ViewBuilder
  private var siteSummaryState: some View {
    if let errorMessage = imageWorkbench.siteSummaryErrorMessage,
       !imageWorkbench.isSiteSummaryLoading {
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

  private var stageDescription: LocalizedStringKey {
    switch stage {
    case .overview:
      return "管理站点图片资源，并在预览影响范围后执行批量处理。"
    case .resources:
      return resourceMode.description
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
        .disabled(repositoryInventory == nil)
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
          resourceMode = .manager
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
        .disabled(imageWorkbench.isSiteSummaryLoading || isRepositoryInventoryLoading)
        .accessibilityLabel("重新扫描文章图片和仓库图片")
        .accessibilityIdentifier("image-workbench-refresh")
      }
      .controlSize(.regular)
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
        MetricTile(title: "可压缩 JPEG", value: "\(summary.optimizableJPEGCount)", systemImage: "arrow.down.forward")
        MetricTile(title: "可转 WebP", value: "\(summary.webPConvertibleCount)", systemImage: "arrow.triangle.2.circlepath")
        MetricTile(title: "可缩放图片", value: "\(summary.resizableImageCount)", systemImage: "arrow.up.left.and.arrow.down.right")
      }

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "lightbulb")
          .foregroundStyle(WorkbenchTheme.navigationSelection)
          .accessibilityHidden(true)
        Text("图片工作区只管理资源。文章缺图、无效引用、过大图片等问题统一到“检查”处理。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
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

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
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
          Text(action.shortDescription)
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 6)
        Text("\(count)")
          .font(.callout.monospacedDigit().weight(.semibold))
      }
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .disabled(count == 0 || imageWorkbench.isProcessingBatch)
    .help(count == 0 ? String(localized: "当前没有符合此操作的图片。") : action.shortDescription)
    .accessibilityLabel(action.title)
    .accessibilityValue(String(format: String(localized: "%d 张图片"), count))
    .accessibilityIdentifier(action.accessibilityIdentifier)
  }

  private var loadingCard: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("正在扫描图片资源…")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func failureCard(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("图片资源扫描失败", systemImage: "exclamationmark.triangle")
        .font(.headline)
        .foregroundStyle(WorkbenchTheme.risk)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Button(action: refreshAll) {
        Label("重新扫描", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var refreshInput: UInt64 {
    store.imageWorkbenchInputRevision
  }

  private var repositoryInventoryRefreshInput: RepositoryInventoryRefreshInput {
    RepositoryInventoryRefreshInput(
      requestID: repositoryRefreshRequestID,
      imageRevision: store.imageWorkbenchInputRevision,
      profileID: store.activeProfile.id,
      repositoryRootPath: store.activeProfile.localRepositoryRootPath,
      assetRoot: store.activeProfile.assetRoot,
      stage: stage,
      resourceMode: resourceMode
    )
  }

  private func presentBatchPreview(
    _ action: ImageWorkbenchBatchAction,
    summary: ImageWorkbenchSiteSummary
  ) {
    let affectedItems: [ImageBatchAffectedItem] = summary.draftSummaries.flatMap { draftSummary in
      draftSummary.items.compactMap { item -> ImageBatchAffectedItem? in
        guard action.includes(item) else { return nil }
        return ImageBatchAffectedItem(
          draftID: draftSummary.draftID,
          draftTitle: draftSummary.draftTitle.nilIfEmpty ?? String(localized: "未命名文章"),
          item: item
        )
      }
    }
    pendingBatchPreview = ImageBatchOperationPreview(
      action: action,
      affectedItems: affectedItems
    )
  }

  private func runBatchOperation(
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
      }
    }
  }

  private func refreshAll() {
    repositoryInventory = nil
    selectedRepositoryPath = nil
    repositoryRefreshRequestID = UUID()
    Task { @MainActor in
      await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
    }
  }

  private func refreshRepositoryInventory() async {
    let profile = store.activeProfile
    let drafts = store.visibleDrafts
    let taskID = UUID()
    activeRepositoryInventoryTaskID = taskID
    isRepositoryInventoryLoading = true
    repositoryInventoryErrorMessage = nil
    repositoryInventory = nil
    selectedRepositoryPath = nil
    defer {
      if activeRepositoryInventoryTaskID == taskID {
        isRepositoryInventoryLoading = false
      }
    }
    do {
      let inventory = try await RepositoryImageInventoryService().inventoryAsync(
        drafts: drafts,
        profile: profile
      )
      try Task.checkCancellation()
      guard profile.id == store.activeProfile.id else { return }
      repositoryInventory = inventory
      repositoryInventoryErrorMessage = nil
      if let selectedRepositoryPath,
         !inventory.assets.contains(where: { $0.repositoryPath == selectedRepositoryPath }) {
        self.selectedRepositoryPath = inventory.assets.first?.repositoryPath
      } else if selectedRepositoryPath == nil {
        selectedRepositoryPath = inventory.assets.first?.repositoryPath
      }
    } catch is CancellationError {
      return
    } catch {
      guard profile.id == store.activeProfile.id else { return }
      repositoryInventory = nil
      repositoryInventoryErrorMessage = error.localizedDescription
    }
  }

  private func attachRepositoryImage(_ asset: RepositoryImageAsset) {
    guard let inventory = repositoryInventory,
          inventory.profileID == store.activeProfile.id,
          inventory.assets.contains(where: { $0.repositoryPath == asset.repositoryPath }),
          let repositoryTargetDraftID,
          store.visibleDrafts.contains(where: { $0.id == repositoryTargetDraftID }) else {
      imageWorkbench.setActionMessage(String(localized: "请选择当前站点中的目标文章。"))
      return
    }
    imageWorkbench.attachRepositoryImage(
      repositoryPath: asset.repositoryPath,
      toDraftID: repositoryTargetDraftID
    )
    repositoryRefreshRequestID = UUID()
  }

  private func openRepositoryImageDirectory() {
    guard let inventory = repositoryInventory,
          inventory.profileID == store.activeProfile.id else { return }
    let directoryURL = URL(fileURLWithPath: inventory.repositoryRootPath, isDirectory: true)
      .appendingPathComponent(inventory.assetRootPath, isDirectory: true)
    NSWorkspace.shared.open(directoryURL)
  }

  private func openWritingForImageInsertion() {
    if store.visibleDrafts.isEmpty {
      store.createDraft()
      return
    }
    store.setDraftListContentScope(.currentSite)
    if let repositoryTargetDraftID {
      _ = store.focusDraft(repositoryTargetDraftID, section: .writing)
    } else {
      store.selectSection(.writing)
    }
  }

  private func normalizeRepositoryTargetDraft() {
    let drafts = store.visibleDrafts
    if let repositoryTargetDraftID,
       drafts.contains(where: { $0.id == repositoryTargetDraftID }) {
      return
    }
    if let selectedDraftID = store.selectedDraftID,
       drafts.contains(where: { $0.id == selectedDraftID }) {
      repositoryTargetDraftID = selectedDraftID
    } else {
      repositoryTargetDraftID = drafts.first?.id
    }
  }

  private func openDraft(_ draftID: UUID) {
    _ = store.focusDraft(draftID, section: .writing)
  }
}

private struct RepositoryInventoryRefreshInput: Hashable {
  let requestID: UUID
  let imageRevision: UInt64
  let profileID: UUID
  let repositoryRootPath: String
  let assetRoot: String
  let stage: ImageWorkbenchContextStage
  let resourceMode: ImageWorkbenchResourceMode
}

private enum ImageWorkbenchResourceMode: String, CaseIterable, Identifiable, Hashable {
  case repository
  case manager

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .repository:
      return "仓库图片"
    case .manager:
      return "资源管理"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .repository:
      return String(localized: "仓库图片")
    case .manager:
      return String(localized: "资源管理")
    }
  }

  var systemImage: String {
    switch self {
    case .repository:
      return "photo.stack"
    case .manager:
      return "archivebox"
    }
  }

  var description: LocalizedStringKey {
    switch self {
    case .repository:
      return "浏览仓库中的图片、查看引用关系，并把图片加入目标文章。"
    case .manager:
      return "扫描全仓库 Markdown 引用，清理孤立资源并安全压缩大图。"
    }
  }
}
