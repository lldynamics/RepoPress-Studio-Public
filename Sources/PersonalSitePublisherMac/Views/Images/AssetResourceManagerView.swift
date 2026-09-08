import AppKit
import PublishingWorkbenchCore
import SwiftUI

private enum AssetResourceManagerFilter: String, CaseIterable, Identifiable {
  case all
  case orphaned
  case broken
  case compressible

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .orphaned: String(localized: "孤立资源")
    case .broken: String(localized: "失效引用")
    case .compressible: String(localized: "可瘦身")
    }
  }
}

private enum AssetResourceManagerPendingAction: String, Identifiable {
  case cleanup
  case compress

  var id: String { rawValue }
}

private struct ImageCompressionAchievement: Identifiable {
  let id = UUID()
  let optimizedCount: Int
  let savedBytes: Int64
  let savedPercentage: Double
  let totalProcessed: Int
}

struct AssetResourceManagerView: View {
  let store: WorkbenchStore
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  @AppStorage("dataManagementRequestedSection") private var dataManagementRequestedSection =
    DataManagementSection.drafts.rawValue

  @State private var report: AssetResourceScanReport?
  @State private var errorMessage: String?
  @State private var isLoading = false
  @State private var filter: AssetResourceManagerFilter = .all
  @State private var selectedOrphanPaths = Set<String>()
  @State private var selectedCompressionPaths = Set<String>()
  @State private var hasInitializedOrphanSelection = false
  @State private var hasInitializedCompressionSelection = false
  @State private var pendingAction: AssetResourceManagerPendingAction?
  @State private var cleanupReview: AssetCleanupReview?
  @State private var cleanupReviewMessage: String?
  @State private var compressionAchievement: ImageCompressionAchievement?
  @State private var repairReplacementPathByReferenceID: [String: String] = [:]
  @State private var repairPreviews: [AssetReferenceRepairPreview] = []
  @State private var selectedRepairPreviewIDs = Set<UUID>()
  @State private var repairMessage: String?
  @State private var repairRecoveryDraftID: UUID?
  @State private var activeScanID: UUID?

  init(store: WorkbenchStore) {
    self.store = store
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      if let achievement = compressionAchievement {
        ImageCompressionAchievementCard(
          achievement: achievement,
          onDismiss: { compressionAchievement = nil }
        )
      }

      if let cleanupReviewMessage {
        WorkbenchStateView(
          presentation: WorkbenchStatePresentation(kind: .failure(reason: cleanupReviewMessage)),
          density: .inline
        )
      }

      if let resourceOperationStatePresentation {
        WorkbenchStateView(
          presentation: resourceOperationStatePresentation,
          density: .inline
        )
      }

      if store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
        emptyRepositoryState
      } else if isLoading, report == nil {
        loadingState
      } else if let report {
        reportContent(report)
      } else if let errorMessage {
        failureState(errorMessage)
      } else {
        loadingState
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("资源管理大总管")
    .accessibilityIdentifier("asset-resource-manager")
    .task(id: scanInput) {
      await refresh()
    }
    .onChange(of: store.activeProfile.id) { _, _ in
      report = nil
      selectedOrphanPaths.removeAll()
      selectedCompressionPaths.removeAll()
      hasInitializedOrphanSelection = false
      hasInitializedCompressionSelection = false
      compressionAchievement = nil
      repairReplacementPathByReferenceID = [:]
      repairPreviews = []
      selectedRepairPreviewIDs = []
      repairMessage = nil
      repairRecoveryDraftID = nil
      pendingAction = nil
      cleanupReview = nil
      cleanupReviewMessage = nil
    }
    .sheet(item: $cleanupReview) { review in
      AssetCleanupConfirmationSheet(
        items: review.items,
        onConfirm: {
          cleanupReview = nil
          runCleanup(review)
        },
        onCancel: { cleanupReview = nil }
      )
    }
    .confirmationDialog(
      "确认开始图片瘦身？",
      isPresented: pendingActionBinding,
      titleVisibility: .visible
    ) {
      Button("开始瘦身", action: runCompression)
      Button("取消", role: .cancel) { pendingAction = nil }
    } message: {
      Text("将尝试压缩 \(selectedCompressionPaths.count) 张图片。只有生成结果更小、且原文件自扫描后未变化时才会原位替换。")
    }
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 14) {
        headerIntroduction
        Spacer(minLength: 10)
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
      Label("资源管理大总管", systemImage: "archivebox")
        .font(.workbenchPageTitle)
      Text("扫描全仓库 Markdown 引用，识别孤立图片/附件、失效本地相对路径和可瘦身图片。")
        .font(.workbenchPageSubtitle)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var headerActions: some View {
    HStack(spacing: 8) {
      Button {
        openAssetDirectory()
      } label: {
        Label("打开资源目录", systemImage: "folder")
      }
      .buttonStyle(.bordered)
      .disabled(report == nil)
      .accessibilityIdentifier("asset-manager-open-folder")

      Button {
        Task { await refresh() }
      } label: {
        Label("重新扫描", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
      .disabled(isLoading)
      .accessibilityLabel("重新扫描资源和 Markdown 引用")
      .accessibilityIdentifier("asset-manager-refresh")
    }
    .controlSize(.regular)
  }

  private func reportContent(_ report: AssetResourceScanReport) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      summary(report)

      if report.wasTruncated || report.skippedMarkdownFileCount > 0 {
        Label {
          Text(scanWarning(report))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.workbenchSupporting)
        .foregroundStyle(WorkbenchTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }

      controls(report)
      filteredContent(report)
    }
    .onAppear { normalizeSelections(report) }
    .onChange(of: report.revisionID) { _, _ in normalizeSelections(report) }
  }

  private func summary(_ report: AssetResourceScanReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("当前站点资源")
            .font(.headline)
          Text(report.assetRootPath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(report.assetRootPath, lineLimit: 2)
        }
        Spacer()
        Text(ByteCountFormatter.string(fromByteCount: report.totalByteSize, countStyle: .file))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
        MetricTile(title: "资源总数", value: "\(report.assets.count)", systemImage: "photo.stack")
        MetricTile(
          title: "孤立资源", value: "\(report.orphanedAssets.count)", systemImage: "questionmark.folder"
        )
        MetricTile(
          title: "失效引用", value: "\(report.brokenReferences.count)", systemImage: "link.badge.plus")
        MetricTile(
          title: "可瘦身图片", value: "\(report.compressionCandidates.count)",
          systemImage: "arrow.down.right.and.arrow.up.left")
      }

      Text("已扫描 \(report.scannedMarkdownFileCount) 个 Markdown 文件；远程 URL、代码块和行内代码不会被当作本地资源。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("资源扫描摘要")
    .accessibilityIdentifier("asset-manager-summary")
  }

  private func controls(_ report: AssetResourceScanReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          filterPicker
          actionButtons(report)
        }
        VStack(alignment: .leading, spacing: 10) {
          filterPicker
          actionButtons(report)
        }
      }
    }
    .padding(12)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  private var filterPicker: some View {
    Picker("资源范围", selection: $filter) {
      ForEach(AssetResourceManagerFilter.allCases) { option in
        Text(option.title).tag(option)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 430)
    .accessibilityIdentifier("asset-manager-filter")
  }

  private func actionButtons(_ report: AssetResourceScanReport) -> some View {
    HStack(spacing: 8) {
      Button {
        cleanupReviewMessage = nil
        cleanupReview = AssetCleanupReview(
          profile: store.activeProfile, report: report, scanInput: scanInput,
          items: report.orphanedAssets.filter { selectedOrphanPaths.contains($0.repositoryPath) }
        )
      } label: {
        Label("清理孤立资源（\(selectedOrphanPaths.count)）", systemImage: "trash")
      }
      .buttonStyle(.bordered)
      .disabled(
        selectedOrphanPaths.isEmpty
          || report.orphanedAssets.isEmpty
          || !report.isComplete
          || isLoading
          || imageWorkbench.hasActiveAssetResourceOperation(for: store.activeProfile.id)
      )
      .accessibilityIdentifier("asset-manager-cleanup")

      Button {
        pendingAction = .compress
      } label: {
        Label(
          "图片瘦身（\(selectedCompressionPaths.count)）",
          systemImage: "arrow.down.right.and.arrow.up.left")
      }
      .workbenchProminentActionStyle()
      .disabled(
        selectedCompressionPaths.isEmpty
          || report.compressionCandidates.isEmpty
          || isLoading
          || imageWorkbench.hasActiveAssetResourceOperation(for: store.activeProfile.id)
      )
      .accessibilityIdentifier("asset-manager-compress")
    }
    .controlSize(.regular)
  }

  @ViewBuilder
  private func filteredContent(_ report: AssetResourceScanReport) -> some View {
    switch filter {
    case .all:
      assetSection(
        title: "孤立资源",
        detail: "这些图片或附件目前没有被任何仓库 Markdown 引用；勾选后可移入废纸篓。",
        items: report.orphanedAssets,
        selection: .orphaned,
        emptyTitle: "没有发现孤立资源",
        emptyMessage: "当前资源目录中的图片和附件都能在 Markdown 中找到引用。"
      )
      assetSection(
        title: "可瘦身图片",
        detail: "仅列出体积或尺寸较大的 JPEG、PNG、HEIC、TIFF；瘦身前会再次校验文件。",
        items: report.compressionCandidates,
        selection: .compressible,
        emptyTitle: "没有可瘦身图片",
        emptyMessage: "当前没有达到建议阈值且格式可安全处理的图片。"
      )
      brokenSection(report)
    case .orphaned:
      assetSection(
        title: "孤立资源",
        detail: "清理操作会把选中项移入 macOS 废纸篓，不会永久删除。",
        items: report.orphanedAssets,
        selection: .orphaned,
        emptyTitle: "没有发现孤立资源",
        emptyMessage: "当前资源目录中的图片和附件都能在 Markdown 中找到引用。"
      )
    case .compressible:
      assetSection(
        title: "可瘦身图片",
        detail: "原文件不会在扫描期间被覆盖；只有优化结果更小才会替换。",
        items: report.compressionCandidates,
        selection: .compressible,
        emptyTitle: "没有可瘦身图片",
        emptyMessage: "当前没有达到建议阈值且格式可安全处理的图片。"
      )
    case .broken:
      brokenSection(report)
    }
  }

  private func assetSection(
    title: LocalizedStringKey,
    detail: LocalizedStringKey,
    items: [AssetResourceItem],
    selection: AssetResourceSelection,
    emptyTitle: LocalizedStringKey,
    emptyMessage: LocalizedStringKey
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(title)
            .font(.workbenchSectionTitle)
          Spacer()
          if !items.isEmpty {
            Button("全选") { selectAll(items, selection: selection) }
              .buttonStyle(.borderless)
            Button("清空") { clearAll(items, selection: selection) }
              .buttonStyle(.borderless)
          }
        }
        Text(detail)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if items.isEmpty {
        EmptyStateView(
          title: emptyTitle,
          message: emptyMessage,
          systemImage: "checkmark.circle",
          density: .compactPane
        )
      } else {
        List {
          ForEach(items) { item in
            Toggle(isOn: selectionBinding(for: item.repositoryPath, selection: selection)) {
              AssetResourceManagerRow(item: item)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier(
              "asset-manager-item-\(AssetResourceIdentifier.token(for: item.repositoryPath))")
          }
        }
        .listStyle(.inset)
        .frame(
          minHeight: 120, idealHeight: min(300, CGFloat(items.count * 54 + 20)), maxHeight: 320
        )
        .accessibilityLabel(title)
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("asset-manager-section-\(selection.rawValue)")
  }

  @ViewBuilder
  private func brokenSection(_ report: AssetResourceScanReport) -> some View {
    let references = report.brokenReferences
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("失效的本地相对路径")
          .font(.workbenchSectionTitle)
        Text("选择已导入文章中的断链来预览替换。其他文件可定位后编辑。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if references.isEmpty {
        EmptyStateView(
          title: "没有发现失效引用",
          message: "当前扫描到的本地图片和附件路径都能定位到资源目录中的文件。",
          systemImage: "link.circle",
          density: .compactPane
        )
      } else {
        List {
          ForEach(references) { reference in
            VStack(alignment: .leading, spacing: 3) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                  .foregroundStyle(WorkbenchTheme.warning)
                  .accessibilityHidden(true)
                Text(reference.rawPath)
                  .font(.callout.weight(.medium))
                  .workbenchTruncatedIdentity(reference.rawPath, lineLimit: 2)
                Spacer()
                Text(reference.kind.workbenchLocalizedDisplayName)
                  .font(.caption)
                  .foregroundStyle(WorkbenchTheme.warning)
              }
              Text("\(reference.sourceMarkdownPath):\(reference.lineNumber) · \(reference.message)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(
                  "\(reference.sourceMarkdownPath):\(reference.lineNumber) · \(reference.message)",
                  lineLimit: 2)
              Picker("替换为", selection: repairReplacementBinding(for: reference.id)) {
                Text("选择本次扫描中的资源").tag("")
                ForEach(report.assets) { asset in
                  Text(asset.repositoryPath).tag(asset.repositoryPath)
                }
              }
              .pickerStyle(.menu)
              HStack {
                Button("预览替换") {
                  prepareRepair(reference: reference, report: report)
                }
                .disabled(repairReplacementPathByReferenceID[reference.id]?.isEmpty != false)
                Button("定位文章") {
                  locateArticle(reference: reference, report: report)
                }
                Button("在 Finder 中显示") {
                  revealSourceFile(reference: reference, report: report)
                }
              }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("失效本地资源引用")
            .accessibilityValue(
              "\(reference.sourceMarkdownPath) 第 \(reference.lineNumber) 行，\(reference.rawPath)，\(reference.message)"
            )
          }
        }
        .listStyle(.inset)
        .frame(
          minHeight: 120, idealHeight: min(260, CGFloat(references.count * 54 + 20)), maxHeight: 300
        )
        .accessibilityIdentifier("asset-manager-broken-reference-list")
      }
      if !repairPreviews.isEmpty {
        Divider()
        Text("替换预览")
          .font(.headline)
        ForEach(repairPreviews) { preview in
          Toggle(isOn: repairPreviewBinding(for: preview.id)) {
            VStack(alignment: .leading, spacing: 2) {
              Text("\(preview.sourcePath):\(preview.lineNumber)")
              Text("\(preview.oldPath) → \(preview.newPath)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
        Button("应用选中的替换（\(selectedRepairPreviewIDs.count)）") {
          applySelectedRepairs(report: report)
        }
        .workbenchProminentActionStyle()
        .disabled(selectedRepairPreviewIDs.isEmpty || isLoading)
      }
      if let repairMessage {
        Text(repairMessage)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
      if let repairRecoveryDraftID {
        Button("打开版本恢复") {
          openVersionHistory(for: repairRecoveryDraftID)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("asset-manager-open-repair-version-history")
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("asset-manager-broken-references")
  }

  private var loadingState: some View {
    WorkbenchStateView(
      presentation: WorkbenchStatePresentation(
        kind: .loading(detail: String(localized: "正在扫描资源和 Markdown 引用…"))
      )
    )
    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
  }

  private var emptyRepositoryState: some View {
    WorkbenchStateView(
      presentation: WorkbenchStatePresentation(
        kind: .unavailable(
          reason: String(
            localized: "资源管理器需要读取本地仓库，才能扫描 static/images 或当前站点配置的资源目录。"
          )
        ),
        icon: "folder.badge.questionmark"
      )
    )
  }

  private func failureState(_ message: String) -> some View {
    WorkbenchStateView(
      presentation: WorkbenchStatePresentation(kind: .failure(reason: message)),
      actions: WorkbenchStateActions(
        primary: WorkbenchStateAction(
          title: "重新扫描",
          systemImage: "arrow.clockwise"
        ) {
          Task { await refresh() }
        }
      )
    )
    .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var scanInput: AssetResourceScanInput {
    AssetResourceScanInput(
      profileID: store.activeProfile.id,
      repositoryRootPath: store.activeProfile.localRepositoryRootPath,
      assetRoot: store.activeProfile.assetRoot,
      contentRevision: store.imageWorkbenchInputRevision,
      resourceOperationCompletionRevision:
        imageWorkbench
        .assetResourceOperationCompletionRevision(for: store.activeProfile.id)
    )
  }

  private var pendingActionBinding: Binding<Bool> {
    Binding(
      get: { pendingAction != nil },
      set: { isPresented in
        if !isPresented { pendingAction = nil }
      }
    )
  }

  private var resourceOperationStatePresentation: WorkbenchStatePresentation? {
    guard
      let operationPresentation = imageWorkbench.assetResourceOperationPresentation(
        for: store.activeProfile.id
      )
    else {
      return nil
    }
    switch operationPresentation {
    case .loading(let detail):
      return WorkbenchStatePresentation(kind: .loading(detail: detail))
    case .success(let detail):
      return WorkbenchStatePresentation(kind: .success(detail: detail))
    case .partialSuccess(let detail):
      return WorkbenchStatePresentation(kind: .partialSuccess(detail: detail))
    case .failure(let reason):
      return WorkbenchStatePresentation(kind: .failure(reason: reason))
    }
  }

  private func refresh() async {
    let profile = store.activeProfile
    let input = scanInput
    if cleanupReview != nil {
      cleanupReviewMessage = AssetResourceManagerError.cleanupReviewChanged.localizedDescription
    }
    cleanupReview = nil
    let taskID = UUID()
    activeScanID = taskID
    isLoading = true
    errorMessage = nil
    defer {
      if activeScanID == taskID { isLoading = false }
    }
    do {
      let result = try await AssetResourceManagerService().scanAsync(profile: profile)
      try Task.checkCancellation()
      guard activeScanID == taskID, input == scanInput else { return }
      report = result
      normalizeSelections(result)
    } catch is CancellationError {
      return
    } catch {
      guard activeScanID == taskID, input == scanInput else { return }
      report = nil
      errorMessage = error.localizedDescription
    }
  }

  private func normalizeSelections(_ report: AssetResourceScanReport) {
    let orphanPaths = Set(report.orphanedAssets.map(\.repositoryPath))
    let compressionPaths = Set(report.compressionCandidates.map(\.repositoryPath))
    let orphanSelection = AssetResourceSelectionPolicy.normalizedSelection(
      currentSelection: selectedOrphanPaths,
      candidates: orphanPaths,
      hasInitializedSelection: hasInitializedOrphanSelection
    )
    selectedOrphanPaths = orphanSelection.selection
    hasInitializedOrphanSelection = orphanSelection.hasInitializedSelection
    let compressionSelection = AssetResourceSelectionPolicy.normalizedSelection(
      currentSelection: selectedCompressionPaths,
      candidates: compressionPaths,
      hasInitializedSelection: hasInitializedCompressionSelection
    )
    selectedCompressionPaths = compressionSelection.selection
    hasInitializedCompressionSelection = compressionSelection.hasInitializedSelection
    // A scan is the immutable baseline for both broken-token offsets and the
    // replacement inventory. Never carry a preview across a fresh scan.
    repairPreviews = []
    selectedRepairPreviewIDs = []
  }

  private func repairReplacementBinding(for referenceID: String) -> Binding<String> {
    Binding(
      get: { repairReplacementPathByReferenceID[referenceID] ?? "" },
      set: { repairReplacementPathByReferenceID[referenceID] = $0 }
    )
  }

  private func repairPreviewBinding(for previewID: UUID) -> Binding<Bool> {
    Binding(
      get: { selectedRepairPreviewIDs.contains(previewID) },
      set: { selected in
        if selected {
          selectedRepairPreviewIDs.insert(previewID)
        } else {
          selectedRepairPreviewIDs.remove(previewID)
        }
      }
    )
  }

  private func prepareRepair(
    reference: AssetResourceBrokenReference, report: AssetResourceScanReport
  ) {
    guard let path = repairReplacementPathByReferenceID[reference.id],
      let replacement = report.assets.first(where: { $0.repositoryPath == path })
    else { return }
    do {
      let preview = try AssetReferenceRepairService().makePreview(
        reference: reference, replacement: replacement, report: report, drafts: store.drafts
      )
      let selectionReplacement = AssetReferenceRepairPreviewSelectionPolicy.replacing(
        preview: AssetReferenceRepairPreviewSelectionCandidate(
          id: preview.id,
          draftID: preview.draftID,
          sourcePath: preview.sourcePath.normalizedRelativePath()
        ),
        existingPreviews: repairPreviews.map {
          AssetReferenceRepairPreviewSelectionCandidate(
            id: $0.id,
            draftID: $0.draftID,
            sourcePath: $0.sourcePath.normalizedRelativePath()
          )
        },
        selectedPreviewIDs: selectedRepairPreviewIDs
      )
      repairPreviews.removeAll { selectionReplacement.removedPreviewIDs.contains($0.id) }
      repairPreviews.append(preview)
      selectedRepairPreviewIDs = selectionReplacement.selectedPreviewIDs
      repairMessage =
        selectionReplacement.removedPreviewIDs.isEmpty
        ? String(localized: "已生成替换预览；应用前会重新校验文章、编辑缓冲和资源路径。")
        : String(localized: "同一篇文章一次只能保留一个待应用替换；已替换该文章先前的预览。")
    } catch {
      repairRecoveryDraftID = importedDraftID(for: reference, report: report)
      repairMessage = error.localizedDescription
    }
  }

  private func applySelectedRepairs(report: AssetResourceScanReport) {
    let selected = repairPreviews.filter { selectedRepairPreviewIDs.contains($0.id) }
    do {
      let result = try store.applyAssetReferenceRepairs(selected, report: report)
      guard result.persistenceSucceeded else {
        repairRecoveryDraftID = result.appliedDraftIDs.first
        repairMessage = String(localized: "替换已写入工作区并保留恢复版本，但持久化失败；请从版本入口恢复或重试。")
        return
      }
      repairMessage = String(localized: "已应用替换并保存可恢复版本，正在重新扫描。")
      repairPreviews.removeAll { selectedRepairPreviewIDs.contains($0.id) }
      selectedRepairPreviewIDs.removeAll()
      Task { await refresh() }
    } catch {
      repairMessage = error.localizedDescription
    }
  }

  private func locateArticle(
    reference: AssetResourceBrokenReference, report: AssetResourceScanReport
  ) {
    guard report.profileID == store.activeProfile.id else {
      repairMessage = String(localized: "站点已切换，请重新扫描后再定位引用。")
      return
    }
    do {
      let location = try AssetReferenceRepairService().editorLocation(
        for: reference,
        report: report,
        drafts: store.drafts
      )
      guard store.focusDraft(location.draftID, section: .writing) else {
        throw AssetReferenceRepairError.unavailableDraft
      }
      store.requestEditorFocus(
        draftID: location.draftID,
        field: "body",
        query: reference.rawPath,
        selectedRange: location.selectedRange
      )
      repairRecoveryDraftID = location.draftID
      repairMessage = String(localized: "已打开文章并选中第 \(reference.lineNumber) 行的失效引用。")
    } catch {
      if let draftID = importedDraftID(for: reference, report: report),
        store.focusDraft(draftID, section: .writing)
      {
        repairRecoveryDraftID = draftID
        repairMessage = String(localized: "已打开文章；第 \(reference.lineNumber) 行的位置已变化，未自动选择。")
        return
      }
      openExternalSourceFile(reference: reference, report: report)
    }
  }

  private func revealSourceFile(
    reference: AssetResourceBrokenReference, report: AssetResourceScanReport
  ) {
    do {
      let source = try AssetReferenceRepairService().sourceURL(
        for: reference.sourceMarkdownPath,
        report: report
      )
      NSWorkspace.shared.activateFileViewerSelecting([source])
      repairMessage = String(
        localized: "已在 Finder 中显示 \(reference.sourceMarkdownPath) 第 \(reference.lineNumber) 行所在文件。")
    } catch {
      repairMessage = error.localizedDescription
    }
  }

  private func openExternalSourceFile(
    reference: AssetResourceBrokenReference, report: AssetResourceScanReport
  ) {
    do {
      let source = try AssetReferenceRepairService().sourceURL(
        for: reference.sourceMarkdownPath,
        report: report
      )
      guard NSWorkspace.shared.open(source) else {
        repairMessage = String(localized: "无法打开仓库文件 \(reference.sourceMarkdownPath)。")
        return
      }
      repairMessage = String(
        localized: "已在默认编辑器打开 \(reference.sourceMarkdownPath)；请编辑第 \(reference.lineNumber) 行。")
    } catch {
      repairMessage = error.localizedDescription
    }
  }

  private func importedDraftID(
    for reference: AssetResourceBrokenReference,
    report: AssetResourceScanReport
  ) -> UUID? {
    store.drafts.first {
      $0.siteProfileID == report.profileID
        && !$0.isGeneralDraft
        && $0.repositoryPath?.normalizedRelativePath()
          == reference.sourceMarkdownPath.normalizedRelativePath()
    }?.id
  }

  private func openVersionHistory(for draftID: UUID) {
    guard store.focusDraft(draftID, section: .writing) else {
      repairMessage = String(localized: "无法打开文章的版本恢复入口。")
      return
    }
    store.flushDraftBodyEditorBuffers()
    dataManagementRequestedSection = DataManagementSection.drafts.rawValue
    SettingsNavigation.present(
      destination: .data(.drafts),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }

  private enum AssetResourceSelection: String {
    case orphaned
    case compressible
  }

  private func selectionBinding(
    for path: String,
    selection: AssetResourceSelection
  ) -> Binding<Bool> {
    Binding(
      get: {
        switch selection {
        case .orphaned: selectedOrphanPaths.contains(path)
        case .compressible: selectedCompressionPaths.contains(path)
        }
      },
      set: { isSelected in
        switch selection {
        case .orphaned:
          hasInitializedOrphanSelection = true
          if isSelected {
            selectedOrphanPaths.insert(path)
          } else {
            selectedOrphanPaths.remove(path)
          }
        case .compressible:
          hasInitializedCompressionSelection = true
          if isSelected {
            selectedCompressionPaths.insert(path)
          } else {
            selectedCompressionPaths.remove(path)
          }
        }
      }
    )
  }

  private func selectAll(_ items: [AssetResourceItem], selection: AssetResourceSelection) {
    switch selection {
    case .orphaned:
      hasInitializedOrphanSelection = true
      selectedOrphanPaths.formUnion(items.map(\.repositoryPath))
    case .compressible:
      hasInitializedCompressionSelection = true
      selectedCompressionPaths.formUnion(items.map(\.repositoryPath))
    }
  }

  private func clearAll(_ items: [AssetResourceItem], selection: AssetResourceSelection) {
    switch selection {
    case .orphaned:
      hasInitializedOrphanSelection = true
      selectedOrphanPaths.subtract(items.map(\.repositoryPath))
    case .compressible:
      hasInitializedCompressionSelection = true
      selectedCompressionPaths.subtract(items.map(\.repositoryPath))
    }
  }

  private func runCleanup(_ review: AssetCleanupReview) {
    pendingAction = nil
    guard !isLoading, review.scanInput == scanInput,
      report?.revisionID == review.report.revisionID, review.report.isComplete
    else {
      cleanupReviewMessage = AssetResourceManagerError.cleanupReviewChanged.localizedDescription
      return
    }
    let items = review.items
    guard !items.isEmpty else { return }
    let profile = review.profile
    let loadingDetail = String(localized: "正在校验并移入废纸篓…")
    guard
      let operationID = imageWorkbench.beginAssetResourceOperation(
        for: profile.id,
        operationTitle: String(localized: "清理孤立资源（\(items.count)）"),
        loadingDetail: loadingDetail
      )
    else {
      return
    }
    Task { @MainActor in
      var completionPresentation: AssetResourceOperationPresentation?
      defer {
        imageWorkbench.finishAssetResourceOperation(
          operationID,
          for: profile.id,
          presentation: completionPresentation
        )
      }
      do {
        let result = try await Task.detached(priority: .utility) {
          try AssetResourceManagerService().moveOrphanedAssetsToTrash(
            profile: profile, items: items, reviewedReport: review.report)
        }.value
        var parts = ["已移入废纸篓 \(result.movedToTrashPaths.count) 个资源"]
        if !result.needsReviewPaths.isEmpty {
          parts.append("\(result.needsReviewPaths.count) 个已完成但未返回废纸篓位置，需复核")
        }
        if !result.failedPaths.isEmpty {
          parts.append("\(result.failedPaths.count) 个未处理")
        }
        let detail = parts.joined(separator: "；") + "。"
        completionPresentation =
          result.needsReviewPaths.isEmpty && result.failedPaths.isEmpty
          ? .success(detail: detail)
          : .partialSuccess(detail: detail)
        guard imageWorkbench.isCurrentAssetResourceOperation(operationID, for: profile.id)
        else { return }
        if store.activeProfile.id == profile.id {
          selectedOrphanPaths.subtract(items.map(\.repositoryPath))
        }
      } catch is CancellationError {
        return
      } catch {
        completionPresentation = .failure(reason: error.localizedDescription)
      }
    }
  }

  private func runCompression() {
    pendingAction = nil
    guard let report else { return }
    let paths = selectedCompressionPaths
    let items = report.compressionCandidates.filter { paths.contains($0.repositoryPath) }
    guard !items.isEmpty else { return }
    let profile = store.activeProfile
    let loadingDetail = String(localized: "正在校验并生成图片优化结果…")
    guard
      let operationID = imageWorkbench.beginAssetResourceOperation(
        for: profile.id,
        operationTitle: String(localized: "图片瘦身（\(items.count)）"),
        loadingDetail: loadingDetail
      )
    else {
      return
    }
    Task { @MainActor in
      var completionPresentation: AssetResourceOperationPresentation?
      defer {
        imageWorkbench.finishAssetResourceOperation(
          operationID,
          for: profile.id,
          presentation: completionPresentation
        )
      }
      do {
        let result = try await Task.detached(priority: .utility) {
          try AssetResourceManagerService().optimizeAssets(profile: profile, items: items)
        }.value
        var parts: [String] = []
        var achievement: ImageCompressionAchievement?
        if !result.optimizedPaths.isEmpty {
          let origBytes = items.filter { result.optimizedPaths.contains($0.repositoryPath) }.reduce(
            0
          ) { $0 + $1.byteSize }
          let pct = origBytes > 0 ? (Double(result.savedBytes) / Double(origBytes) * 100.0) : 0.0
          achievement = ImageCompressionAchievement(
            optimizedCount: result.optimizedPaths.count,
            savedBytes: result.savedBytes,
            savedPercentage: pct,
            totalProcessed: items.count
          )
          parts.append(
            "已瘦身 \(result.optimizedPaths.count) 张图片，减少 \(ByteCountFormatter.string(fromByteCount: result.savedBytes, countStyle: .file))"
          )
        } else {
          parts.append("没有图片在优化后变得更小")
        }
        if !result.skippedPaths.isEmpty { parts.append("\(result.skippedPaths.count) 张保留原文件") }
        if !result.failedPaths.isEmpty { parts.append("\(result.failedPaths.count) 张处理失败") }
        let detail = parts.joined(separator: "；") + "。"
        completionPresentation =
          result.skippedPaths.isEmpty && result.failedPaths.isEmpty
          ? .success(detail: detail)
          : .partialSuccess(detail: detail)
        guard imageWorkbench.isCurrentAssetResourceOperation(operationID, for: profile.id)
        else { return }
        if store.activeProfile.id == profile.id {
          compressionAchievement = achievement
          selectedCompressionPaths.subtract(items.map(\.repositoryPath))
        }
      } catch is CancellationError {
        return
      } catch {
        completionPresentation = .failure(reason: error.localizedDescription)
      }
    }
  }

  private func scanWarning(_ report: AssetResourceScanReport) -> String {
    var parts: [String] = []
    if report.skippedMarkdownFileCount > 0 {
      parts.append("有 \(report.skippedMarkdownFileCount) 个 Markdown 文件过大或无法读取")
    }
    if report.wasTruncated {
      parts.append("扫描达到安全数量或累计读取字节预算")
    }
    return parts.joined(separator: "；") + "，结果不完整；不会开放孤立资源清理，请先处理后重新扫描。"
  }

  private func openAssetDirectory() {
    guard let report else { return }
    let url = URL(fileURLWithPath: report.repositoryRootPath, isDirectory: true)
      .appendingPathComponent(report.assetRootPath, isDirectory: true)
    NSWorkspace.shared.open(url)
  }
}

private struct ImageCompressionAchievementCard: View {
  let achievement: ImageCompressionAchievement
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      ZStack {
        Circle()
          .fill(WorkbenchTheme.success.opacity(0.18))
          .frame(width: 42, height: 42)
        Image(systemName: "sparkles")
          .font(.title3)
          .foregroundStyle(WorkbenchTheme.success)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(
          "成功为 \(achievement.optimizedCount) 张图片瘦身，节省了 \(ByteCountFormatter.string(fromByteCount: achievement.savedBytes, countStyle: .file)) (\(Int(round(achievement.savedPercentage)))%) 存储空间"
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.success)

        Text("已自动将更优体积的原位替换，优化后未发生体积下降的图片已原样保留。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(6)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭瘦身成就卡片")
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchTheme.success.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(WorkbenchTheme.success.opacity(0.3), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片瘦身成就")
  }
}

private struct AssetCleanupConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  let items: [AssetResourceItem]
  let onConfirm: () -> Void
  let onCancel: () -> Void

  private var representativeItems: [AssetResourceItem] {
    Array(items.prefix(5))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("确认清理孤立资源？", systemImage: "trash")
          .font(.headline)
        Spacer()
        Button("取消") {
          onCancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.uturn.backward.circle.fill")
            .foregroundStyle(WorkbenchTheme.success)
          Text("可随时在 macOS 废纸篓恢复")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WorkbenchTheme.success)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          WorkbenchTheme.success.opacity(0.12),
          in: Capsule()
        )

        Text("以下选中的 \(items.count) 个资源未在任何 Markdown 文章中找到引用。执行后将移入系统废纸篓，不会被永久删除。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("待清理代表性文件预览（前 \(representativeItems.count) 项）：")
          .font(.caption.weight(.semibold))

        VStack(alignment: .leading, spacing: 6) {
          ForEach(representativeItems) { item in
            HStack(spacing: 8) {
              Image(systemName: item.kind.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20)

              VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                  .font(.caption.weight(.medium))
                  .lineLimit(1)
                Text(item.repositoryPath)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

              Spacer(minLength: 8)

              Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                .font(.workbenchMetadata.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(6)
            .background(
              WorkbenchBackgroundStyle.control,
              in: RoundedRectangle(cornerRadius: 6)
            )
          }

          if items.count > representativeItems.count {
            Text(
              String(
                format: String(localized: "…以及另外 %lld 个未列出的资源文件。"),
                Int64(items.count - representativeItems.count)
              )
            )
            .font(.workbenchMetadata)
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
          }
        }
      }

      Spacer(minLength: 0)

      HStack {
        Button("取消", role: .cancel) {
          onCancel()
          dismiss()
        }
        Spacer()
        Button(role: .destructive) {
          onConfirm()
          dismiss()
        } label: {
          Label("移入废纸篓（\(items.count) 个）", systemImage: "trash")
        }
        .workbenchProminentActionStyle()
      }
    }
    .padding(18)
    .frame(minWidth: 480, idealWidth: 540, minHeight: 380, idealHeight: 460)
    .accessibilityLabel("孤立资源清理确认")
  }
}

private struct AssetCleanupReview: Identifiable {
  let id = UUID()
  let profile: SiteProfile
  let report: AssetResourceScanReport
  let scanInput: AssetResourceScanInput
  let items: [AssetResourceItem]
}

private struct AssetResourceScanInput: Hashable {
  let profileID: UUID
  let repositoryRootPath: String
  let assetRoot: String
  let contentRevision: UInt64
  let resourceOperationCompletionRevision: UInt64
}

private enum AssetResourceIdentifier {
  static func token(for path: String) -> String {
    path.unicodeScalars
      .map { scalar in
        scalar.isASCII
          && (scalar == "-" || scalar == "_" || scalar == "." || scalar == "/"
            || scalar.properties.isASCIIHexDigit || scalar.properties.isAlphabetic)
          ? String(scalar) : "-"
      }
      .joined()
      .replacingOccurrences(of: "/", with: "-")
  }
}

private struct AssetResourceManagerRow: View {
  let item: AssetResourceItem

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.kind.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.filename)
          .font(.body.weight(.medium))
          .workbenchTruncatedIdentity(item.filename)
        Text(item.repositoryPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(item.repositoryPath)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
          .font(.caption.monospacedDigit())
        if let dimensions = item.dimensions {
          Text(dimensions.workbenchDimensionText)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(item.kind.workbenchLocalizedDisplayName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.filename)
    .accessibilityValue(
      "\(item.kind.workbenchLocalizedDisplayName)，\(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))，\(item.references.count) 个 Markdown 引用"
    )
  }
}
