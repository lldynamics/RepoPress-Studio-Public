import PublishingWorkbenchCore
import SwiftUI

struct ImageWorkbenchView: View {
  let store: WorkbenchStore
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade
  @State private var pendingBatchPreview: ImageBatchOperationPreview?
  @State private var showsAllAffectedDrafts = false
  @State private var selectedImageDraftID: UUID?

  init(store: WorkbenchStore) {
    self.store = store
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          batchStatus

          if let summary = store.cachedImageWorkbenchSiteSummary {
            siteWideSummary(
              summary,
              usesSplitLayout: WorkbenchPageMetrics.usesOperationalSplit(for: geometry.size.width)
            )
          } else if let errorMessage = imageWorkbench.siteSummaryErrorMessage,
                    !imageWorkbench.isSiteSummaryLoading {
            failureCard(errorMessage)
          } else {
            loadingCard
          }
        }
        .workbenchOperationalPageLayout()
      }
    }
    .accessibilityLabel("全站图片优化")
    .task(id: refreshInput) {
      await store.refreshImageWorkbenchSiteSummaryInBackground()
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

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("全站图片优化")
          .font(.title2.weight(.semibold))
        Text("这里只处理跨文章扫描、批量压缩和格式转换；当前文章图片请在 Inspector 中编辑。")
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let summary = store.cachedImageWorkbenchSiteSummary,
         summary.imageCount > 0 {
        Button {
          Task { @MainActor in
            await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
          }
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(imageWorkbench.isSiteSummaryLoading)
        .accessibilityLabel("刷新全站图片扫描")
      }
    }
  }

  @ViewBuilder
  private var batchStatus: some View {
    if let message = imageWorkbench.actionMessage {
      Label(message, systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    if let progress = imageWorkbench.batchProgress {
      HStack(spacing: 10) {
        HStack(spacing: 10) {
          ProgressView(value: progress.fractionCompleted)
            .frame(maxWidth: 220)
          Text(progress.operation.progressTitle)
          Text("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("全站图片处理进度")
        .accessibilityValue("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
        Spacer()
        Button("取消") {
          imageWorkbench.cancelBatchProcessing()
        }
      }
      .accessibilityElement(children: .contain)
    }
  }

  private func siteWideSummary(
    _ summary: ImageWorkbenchSiteSummary,
    usesSplitLayout: Bool
  ) -> some View {
    WorkbenchOperationalSplitLayout(usesSplitLayout: usesSplitLayout) {
      siteWideSummaryPrimary(summary)
    } context: {
      imageOperationalContextPanel(summary)
    }
  }

  private func siteWideSummaryPrimary(_ summary: ImageWorkbenchSiteSummary) -> some View {
    let metrics = issueMetrics(for: summary)
    let affectedDrafts = summary.draftSummaries.filter { $0.issueCount > 0 }
    let selectedDraftID = selectedImageDraftSummary(in: summary)?.draftID

    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("站点图片扫描")
            .font(.headline)
          Text(
            "\(summary.draftCount) 篇文章 · \(summary.imageCount) 张图片 · "
              + ByteCountFormatter.string(fromByteCount: summary.totalByteSize, countStyle: .file)
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
      }

      if summary.imageCount == 0 {
        EmptyStateView(
          title: "还没有可扫描的图片",
          message: "在文章中添加图片后，这里会显示缺失元数据、重复文件和可优化格式。",
          systemImage: "photo.on.rectangle.angled",
          density: .compactPane,
          actionTitle: store.selectedDraftID == nil ? "新建文章并插图" : "前往写作并插图",
          actionSystemImage: "photo.badge.plus",
          action: {
            if store.selectedDraftID == nil {
              store.createDraft()
            } else {
              store.selectSection(.writing)
            }
          }
        )
      } else if metrics.isEmpty {
        Label("没有需要批量处理的图片问题。", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
          .padding(.vertical, 10)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
          spacing: 12
        ) {
          ForEach(metrics) { metric in
            MetricTile(
              title: metric.title,
              value: String(metric.value),
              systemImage: metric.systemImage
            )
          }
        }
      }

      if !affectedDrafts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("待处理文章")
              .font(.callout.weight(.medium))
            Spacer()
            Text("\(affectedDrafts.count) 篇")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          let visibleAffectedDrafts = showsAllAffectedDrafts
            ? affectedDrafts
            : Array(affectedDrafts.prefix(20))
          ForEach(visibleAffectedDrafts) { draftSummary in
            let isSelected = selectedDraftID == draftSummary.draftID
            Button {
              selectedImageDraftID = draftSummary.draftID
              store.selectDraft(draftSummary.draftID)
            } label: {
              HStack(spacing: 10) {
                Image(systemName: draftSummary.errorCount > 0 ? "xmark.octagon" : "exclamationmark.triangle")
                  .foregroundStyle(draftSummary.errorCount > 0 ? WorkbenchTheme.risk : WorkbenchTheme.warning)
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(draftSummary.draftTitle)
                    .workbenchTruncatedIdentity(draftSummary.draftTitle)
                  Text(issueSummary(for: draftSummary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                Text("\(draftSummary.issueCount)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                  .foregroundStyle(
                    isSelected ? WorkbenchTheme.navigationSelection : Color.secondary
                  )
              }
              .padding(8)
              .background {
                RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
                  .fill(
                    isSelected
                      ? AnyShapeStyle(
                        WorkbenchTheme.navigationSelection.opacity(
                          WorkbenchOpacity.selectionBackground
                        )
                      )
                      : WorkbenchBackgroundStyle.subtle
                  )
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择 \(draftSummary.draftTitle) 查看图片问题")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
          }

          if affectedDrafts.count > 20 {
            WorkbenchListDisclosureFooter(
              visibleCount: visibleAffectedDrafts.count,
              totalCount: affectedDrafts.count,
              showsAll: $showsAllAffectedDrafts
            )
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func imageOperationalContextPanel(_ summary: ImageWorkbenchSiteSummary) -> some View {
    let selectedDraft = selectedImageDraftSummary(in: summary)

    return VStack(alignment: .leading, spacing: 12) {
      Label("当前文章", systemImage: "sidebar.right")
        .font(.headline)

      if let selectedDraft {
        Text(selectedDraft.draftTitle)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(selectedDraft.draftTitle)

        InspectorStatRow(
          title: "图片",
          value: "\(selectedDraft.imageCount)",
          systemImage: "photo.on.rectangle"
        )
        InspectorStatRow(
          title: "错误",
          value: "\(selectedDraft.errorCount)",
          systemImage: "xmark.octagon"
        )
        InspectorStatRow(
          title: "警告",
          value: "\(selectedDraft.warningCount)",
          systemImage: "exclamationmark.triangle"
        )

        let metrics = issueMetrics(for: selectedDraft)
        if !metrics.isEmpty {
          Divider()
          ForEach(metrics.prefix(7)) { metric in
            HStack(spacing: 8) {
              Image(systemName: metric.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
              Text(LocalizedStringKey(metric.title))
                .font(.caption)
              Spacer()
              Text("\(metric.value)")
                .font(.caption.monospacedDigit())
            }
          }
        }

        Button {
          guard store.focusDraft(selectedDraft.draftID, section: .images) else { return }
          store.setInspectorPresented(true)
        } label: {
          Label("Inspector", systemImage: "sidebar.right")
        }
        .buttonStyle(.bordered)
      } else {
        Label("没有需要批量处理的图片问题。", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
      }

      if summary.imageCount > 0 {
        Divider()
        optimizationMenu(summary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前文章")
  }

  private func selectedImageDraftSummary(
    in summary: ImageWorkbenchSiteSummary
  ) -> ImageWorkbenchDraftSummary? {
    let affectedDrafts = summary.draftSummaries.filter { $0.issueCount > 0 }
    if let selectedImageDraftID,
       let selected = affectedDrafts.first(where: { $0.draftID == selectedImageDraftID }) {
      return selected
    }
    if let selectedDraftID = store.selectedDraftID,
       let selected = affectedDrafts.first(where: { $0.draftID == selectedDraftID }) {
      return selected
    }
    return affectedDrafts.first
  }

  private func optimizationMenu(_ summary: ImageWorkbenchSiteSummary) -> some View {
    Menu {
      Button {
        presentBatchPreview(.fillMetadata, summary: summary)
      } label: {
        Label("补全 alt/caption", systemImage: "text.badge.checkmark")
      }

      Divider()

      Button {
        presentBatchPreview(.file(.optimizeJPEG), summary: summary)
      } label: {
        Label("压缩 JPEG", systemImage: "photo.stack")
      }
      .disabled(summary.optimizableJPEGCount == 0)

      Button {
        presentBatchPreview(.file(.convertWebP), summary: summary)
      } label: {
        Label("转换为 WebP", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(summary.webPConvertibleCount == 0)

      Button {
        presentBatchPreview(.file(.optimizeSVG), summary: summary)
      } label: {
        Label("优化 SVG", systemImage: "wand.and.stars")
      }
      .disabled(summary.optimizableSVGCount == 0)

      Button {
        presentBatchPreview(.file(.resizeLargeImages), summary: summary)
      } label: {
        Label("缩放大图", systemImage: "arrow.down.right.and.arrow.up.left")
      }
      .disabled(summary.resizableImageCount == 0)
    } label: {
      Label("优化…", systemImage: "slider.horizontal.3")
    }
    .disabled(imageWorkbench.isProcessingBatch)
    .accessibilityLabel("优化全站图片")
  }

  private var loadingCard: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("正在统计站点图片…")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func failureCard(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("图片扫描失败", systemImage: "exclamationmark.triangle")
        .font(.headline)
        .foregroundStyle(WorkbenchTheme.risk)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Button {
        Task { @MainActor in
          await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
        }
      } label: {
        Label("重新扫描", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
  }

  private var refreshInput: UInt64 {
    store.imageWorkbenchInputRevision
  }

  private func issueMetrics(for summary: ImageWorkbenchSiteSummary) -> [ImageOptimizationMetric] {
    [
      ImageOptimizationMetric(title: "错误", value: summary.errorCount, systemImage: "xmark.octagon"),
      ImageOptimizationMetric(title: "警告", value: summary.warningCount, systemImage: "exclamationmark.triangle"),
      ImageOptimizationMetric(title: "缺 alt", value: summary.missingAltTextCount, systemImage: "text.quote"),
      ImageOptimizationMetric(title: "源图缺失", value: summary.missingSourceCount, systemImage: "questionmark.folder"),
      ImageOptimizationMetric(title: "重复图片", value: summary.duplicateImageCount, systemImage: "square.on.square"),
      ImageOptimizationMetric(title: "可压缩 JPEG", value: summary.optimizableJPEGCount, systemImage: "arrow.down.forward"),
      ImageOptimizationMetric(title: "可转 WebP", value: summary.webPConvertibleCount, systemImage: "arrow.triangle.2.circlepath"),
      ImageOptimizationMetric(title: "可优化 SVG", value: summary.optimizableSVGCount, systemImage: "wand.and.stars"),
      ImageOptimizationMetric(title: "可缩放", value: summary.resizableImageCount, systemImage: "arrow.down.right.and.arrow.up.left"),
    ]
    .filter { $0.value > 0 }
  }

  private func issueMetrics(for summary: ImageWorkbenchDraftSummary) -> [ImageOptimizationMetric] {
    [
      ImageOptimizationMetric(title: "缺 alt", value: summary.missingAltTextCount, systemImage: "text.quote"),
      ImageOptimizationMetric(title: "源图缺失", value: summary.missingSourceCount, systemImage: "questionmark.folder"),
      ImageOptimizationMetric(title: "重复图片", value: summary.duplicateImageCount, systemImage: "square.on.square"),
      ImageOptimizationMetric(title: "可压缩 JPEG", value: summary.optimizableJPEGCount, systemImage: "arrow.down.forward"),
      ImageOptimizationMetric(title: "可转 WebP", value: summary.webPConvertibleCount, systemImage: "arrow.triangle.2.circlepath"),
      ImageOptimizationMetric(title: "可优化 SVG", value: summary.optimizableSVGCount, systemImage: "wand.and.stars"),
      ImageOptimizationMetric(title: "可缩放", value: summary.resizableImageCount, systemImage: "arrow.down.right.and.arrow.up.left"),
    ]
    .filter { $0.value > 0 }
  }

  private func issueSummary(for summary: ImageWorkbenchDraftSummary) -> String {
    [
      summary.missingAltTextCount > 0 ? "缺 alt \(summary.missingAltTextCount)" : nil,
      summary.missingSourceCount > 0 ? "源图缺失 \(summary.missingSourceCount)" : nil,
      summary.duplicateImageCount > 0 ? "重复 \(summary.duplicateImageCount)" : nil,
      summary.optimizableJPEGCount > 0 ? "JPEG \(summary.optimizableJPEGCount)" : nil,
      summary.webPConvertibleCount > 0 ? "WebP \(summary.webPConvertibleCount)" : nil,
      summary.optimizableSVGCount > 0 ? "SVG \(summary.optimizableSVGCount)" : nil,
      summary.resizableImageCount > 0 ? "大图 \(summary.resizableImageCount)" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private func presentBatchPreview(
    _ action: ImageWorkbenchBatchAction,
    summary: ImageWorkbenchSiteSummary
  ) {
    let draftsByID = Dictionary(uniqueKeysWithValues: store.visibleDrafts.map { ($0.id, $0) })
    let affectedItems = summary.draftSummaries.flatMap { draftSummary -> [ImageBatchAffectedItem] in
      guard let draft = draftsByID[draftSummary.draftID] else { return [] }
      let report = store.imageWorkbenchReport(for: draft)
      return report.items.compactMap { item in
        guard action.includes(item) else { return nil }
        return ImageBatchAffectedItem(
          draftID: draft.id,
          draftTitle: draft.title.nilIfEmpty ?? String(localized: "未命名文章"),
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
}

private struct ImageOptimizationMetric: Identifiable {
  let title: String
  let value: Int
  let systemImage: String

  var id: String { title }
}

private enum ImageWorkbenchBatchAction {
  case fillMetadata
  case file(ImageBatchOperation)

  var title: String {
    switch self {
    case .fillMetadata: String(localized: "补全 alt/caption")
    case .file(let operation): operation.progressTitle
    }
  }

  var isMetadataFill: Bool {
    if case .fillMetadata = self { return true }
    return false
  }

  var systemImage: String {
    switch self {
    case .fillMetadata: "text.badge.checkmark"
    case .file: "photo.stack"
    }
  }

  var outputDescription: String {
    switch self {
    case .fillMetadata:
      return String(localized: "补全所选图片缺失的 alt 和 caption，并同步正文中的空图片替代文本。")
    case .file(.optimizeJPEG):
      return String(localized: "生成优化后的 JPEG 副本，保留 JPEG 格式。")
    case .file(.convertWebP):
      return String(localized: "生成 WebP 副本，并把草稿图片引用更新为 WebP。")
    case .file(.optimizeSVG):
      return String(localized: "生成精简后的 SVG 副本，保留 SVG 格式。")
    case .file(.resizeLargeImages):
      return String(localized: "按原格式生成缩小尺寸的图片副本。")
    case .file(.cropCover16By9):
      return String(localized: "生成 16:9 的封面副本。")
    }
  }

  var estimatedSavingRatio: Double {
    switch self {
    case .fillMetadata: 0
    case .file(.optimizeJPEG): 0.18
    case .file(.convertWebP): 0.28
    case .file(.optimizeSVG): 0.12
    case .file(.resizeLargeImages): 0.35
    case .file(.cropCover16By9): 0.20
    }
  }

  func includes(_ item: ImageWorkbenchItem) -> Bool {
    switch self {
    case .fillMetadata:
      return item.missingAltText || item.missingCaption
    case .file(.optimizeJPEG):
      return item.canOptimizeJPEG
    case .file(.convertWebP):
      return item.canConvertToWebP
    case .file(.optimizeSVG):
      return item.canOptimizeSVG
    case .file(.resizeLargeImages):
      return item.canResizeImage
    case .file(.cropCover16By9):
      return item.isCover
    }
  }
}

private struct ImageBatchAffectedItem: Identifiable {
  let draftID: UUID
  let draftTitle: String
  let item: ImageWorkbenchItem

  var id: UUID { item.attachmentID }

  var detail: String {
    var parts: [String] = []
    if item.missingAltText { parts.append(String(localized: "缺 alt")) }
    if item.missingCaption { parts.append(String(localized: "缺 caption")) }
    if item.byteSize > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
    }
    if let dimensions = item.dimensions {
      parts.append("\(dimensions.width)×\(dimensions.height)")
    }
    return parts.joined(separator: " · ")
  }
}

private struct ImageBatchOperationPreview: Identifiable {
  let id = UUID()
  let action: ImageWorkbenchBatchAction
  let affectedItems: [ImageBatchAffectedItem]
}

private struct ImageBatchOperationPreviewView: View {
  let preview: ImageBatchOperationPreview
  let cancel: () -> Void
  let confirm: ([UUID: Set<UUID>]) -> Void
  @State private var selectedAttachmentIDs: Set<UUID>

  init(
    preview: ImageBatchOperationPreview,
    cancel: @escaping () -> Void,
    confirm: @escaping ([UUID: Set<UUID>]) -> Void
  ) {
    self.preview = preview
    self.cancel = cancel
    self.confirm = confirm
    _selectedAttachmentIDs = State(initialValue: Set(preview.affectedItems.map(\.id)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Label("确认\(preview.action.title)", systemImage: preview.action.systemImage)
          .font(.title3.weight(.semibold))
        Text("逐项核对影响文章和图片；取消勾选即可排除单张图片。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
        MetricTile(title: "影响文章", value: "\(selectedDraftCount)", systemImage: "doc.text")
        MetricTile(title: "影响图片", value: "\(selectedItems.count)", systemImage: "photo.on.rectangle")
        MetricTile(
          title: preview.action.isMetadataFill ? "待补字段" : "预计节省",
          value: preview.action.isMetadataFill
            ? "\(selectedMetadataFieldCount)"
            : ByteCountFormatter.string(fromByteCount: estimatedSavedBytes, countStyle: .file),
          systemImage: preview.action.isMetadataFill ? "textformat" : "arrow.down.circle"
        )
      }

      HStack {
        Text("影响明细")
          .font(.headline)
        Spacer()
        Button("全选") {
          selectedAttachmentIDs = Set(preview.affectedItems.map(\.id))
        }
        .disabled(selectedAttachmentIDs.count == preview.affectedItems.count)
        Button("全部排除") {
          selectedAttachmentIDs.removeAll()
        }
        .disabled(selectedAttachmentIDs.isEmpty)
      }

      List(preview.affectedItems) { affected in
        Toggle(isOn: selectionBinding(for: affected.id)) {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo")
              .foregroundStyle(.secondary)
              .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
              Text(affected.item.originalFilename)
                .font(.callout.weight(.medium))
                .workbenchTruncatedIdentity(affected.item.originalFilename)
              Text(affected.draftTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(affected.draftTitle)
              if !affected.detail.isEmpty {
                Text(affected.detail)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
          }
        }
        .toggleStyle(.checkbox)
      }
      .frame(minHeight: 230, idealHeight: 300)

      GroupBox(String(localized: "输出与恢复")) {
        VStack(alignment: .leading, spacing: 6) {
          Text(preview.action.outputDescription)
          Label("开始前会为每篇受影响文章创建“批处理前”版本点。", systemImage: "clock.arrow.circlepath")
          Label("文件处理期间可以取消；未应用的临时文件会被清理。", systemImage: "xmark.circle")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button("取消", action: cancel)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button {
          confirm(selectionByDraft)
        } label: {
          Label("确认并开始（\(selectedItems.count) 张）", systemImage: "play.fill")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(selectedAttachmentIDs.isEmpty)
      }
    }
    .padding(22)
    .frame(minWidth: 640, idealWidth: 720, minHeight: 620, idealHeight: 720)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片批处理影响预览")
  }

  private var selectedItems: [ImageBatchAffectedItem] {
    preview.affectedItems.filter { selectedAttachmentIDs.contains($0.id) }
  }

  private var selectedDraftCount: Int {
    Set(selectedItems.map(\.draftID)).count
  }

  private var selectedMetadataFieldCount: Int {
    selectedItems.reduce(0) { count, affected in
      count + (affected.item.missingAltText ? 1 : 0) + (affected.item.missingCaption ? 1 : 0)
    }
  }

  private var estimatedSavedBytes: Int64 {
    let selectedBytes = selectedItems.reduce(Int64(0)) { $0 + max(0, $1.item.byteSize) }
    return Int64(Double(selectedBytes) * preview.action.estimatedSavingRatio)
  }

  private var selectionByDraft: [UUID: Set<UUID>] {
    Dictionary(grouping: selectedItems, by: \.draftID)
      .mapValues { Set($0.map(\.id)) }
  }

  private func selectionBinding(for attachmentID: UUID) -> Binding<Bool> {
    Binding(
      get: { selectedAttachmentIDs.contains(attachmentID) },
      set: { isSelected in
        if isSelected {
          selectedAttachmentIDs.insert(attachmentID)
        } else {
          selectedAttachmentIDs.remove(attachmentID)
        }
      }
    )
  }
}
