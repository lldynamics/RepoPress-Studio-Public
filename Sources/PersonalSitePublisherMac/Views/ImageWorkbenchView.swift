import AppKit
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers

struct ImageWorkbenchView: View {
  let store: WorkbenchStore
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade
  @State private var isImageDropTarget = false

  init(store: WorkbenchStore) {
    self.store = store
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header

        if let message = imageWorkbench.actionMessage {
          Label(message, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let progress = imageWorkbench.batchProgress {
          HStack(spacing: 10) {
            ProgressView(value: progress.fractionCompleted)
              .frame(maxWidth: 180)
            Text(progress.operation.progressTitle)
            Text("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("取消") {
              store.imageWorkbench.cancelBatchProcessing()
            }
            .disabled(!imageWorkbench.isProcessingBatch)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("图片处理进度")
          .accessibilityValue("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
        }

        if let summary = store.cachedImageWorkbenchSiteSummary {
          siteWideSummary(summary)
        } else {
          loadingCard(String(localized: "正在统计站点图片…"))
        }

        if let draft = store.selectedDraft {
          selectedDraftSection(draft, report: imageWorkbench.cachedReport(for: draft))
        } else {
          EmptyStateView(
            title: "还没有选择文章",
            message: "选择一篇草稿后，可以检查图片路径、封面、alt/caption 和发布源文件。",
            systemImage: "photo.badge.exclamationmark"
          )
          .frame(height: 280)
        }
      }
      .padding(20)
    }
    .overlay(alignment: .center) {
      if isImageDropTarget {
        dropTargetOverlay
          .allowsHitTesting(false)
      }
    }
    .onDrop(
      of: [UTType.fileURL.identifier],
      isTargeted: $isImageDropTarget,
      perform: handleDroppedImageProviders
    )
    .accessibilityLabel("图片工作台")
    .accessibilityHint("拖入图片文件到此处")
    .task(id: imageWorkbenchRefreshInput) {
      if let draft = store.selectedDraft {
        await store.refreshImageWorkbenchCachesInBackground(for: draft)
        store.imageWorkbench.prepareAISuggestions(for: draft)
      } else {
        await store.refreshImageWorkbenchSiteSummaryInBackground()
      }
    }
    .onChange(of: store.selectedDraftID) { _, _ in
      if let draft = store.selectedDraft {
        store.imageWorkbench.prepareAISuggestions(for: draft)
      }
    }
  }

  @ViewBuilder
  private func selectedDraftSection(_ draft: ArticleDraft, report: ImageWorkbenchReport?) -> some View {
    Text("当前文章")
      .font(.headline)
    if imageWorkbench.isReportLoading(for: draft), report == nil {
      ProgressView {
        Text("正在读取当前文章图片…")
      }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    metrics(report: report)
    coverStatus(report?.coverStatus)
    issues(report: report)
    if store.imageWorkbench.suggestionDraftID == draft.id,
       !store.imageWorkbench.suggestions.isEmpty {
      aiImageTextSuggestionsSection(store.imageWorkbench.suggestions.filter { $0.draftID == draft.id })
    }

    if draft.attachments.isEmpty {
      EmptyStateView(
        title: "当前文章还没有图片",
        message: "可以在编辑器里拖入图片，或从这里添加图片引用。",
        systemImage: "photo.on.rectangle"
      )
      .frame(height: 260)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        let itemsByAttachmentID = Dictionary(uniqueKeysWithValues: (report?.items ?? []).map { ($0.attachmentID, $0) })
        ForEach(draft.attachments) { attachment in
          let item = itemsByAttachmentID[attachment.id]
          imageRow(draft: draft, attachment: attachment, item: item)
        }
      }
    }
  }

  private func imageRow(
    draft: ArticleDraft,
    attachment: DraftAttachment,
    item: ImageWorkbenchItem?
  ) -> some View {
    ImageWorkbenchRow(
      attachment: attachment,
      item: item,
      isCover: draft.coverAttachmentID == attachment.id,
      altText: binding(for: attachment.id, keyPath: \.altText),
      caption: binding(for: attachment.id, keyPath: \.caption),
      setCover: {
        store.setSelectedDraftCoverAttachment(attachment.id)
      },
      clearCover: {
        store.setSelectedDraftCoverAttachment(nil)
      }
    )
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("图片工作台")
          .font(.title2.weight(.semibold))
        Text("批量检查封面、发布路径、alt/caption、本地源图、重复引用、裁剪缩放、JPEG 压缩、WebP 转换和 SVG 优化。")
          .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 8) {
        Button {
          Task { @MainActor in
            if let draft = store.selectedDraft {
              await store.refreshImageWorkbenchCachesInBackground(for: draft, force: true)
            } else {
              await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
            }
          }
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .accessibilityLabel("刷新图片工作台")

        Button {
          insertImages(ImageSelectionPanel.chooseImages())
        } label: {
          Label("添加图片", systemImage: "photo.badge.plus")
        }
        .accessibilityLabel("添加图片到当前文章")

        Button {
          guard let draft = store.publishing.selectedDraft else {
            return
          }
          Task {
            await imageWorkbench.generateAISuggestions(draft: draft)
          }
        } label: {
          Label(imageWorkbench.isGeneratingSuggestions ? "AI 生成中" : "AI 补 alt/caption", systemImage: "sparkles")
        }
        .disabled(!aiImageTextGenerationAvailability.isEnabled)
        .help(aiImageTextGenerationAvailability.unavailableReason ?? "根据当前文章和图片上下文生成 alt/caption")
        .accessibilityLabel(imageWorkbench.isGeneratingSuggestions ? "AI 正在生成图片文案" : "AI 补全图片文案")
        .accessibilityHint(aiImageTextGenerationAvailability.unavailableReason ?? "根据当前文章和图片上下文生成 alt 和 caption")

        Menu {
          Button {
            store.imageWorkbench.fillMissingMetadataForSelectedDraft()
          } label: {
            Label("补当前文案", systemImage: "text.badge.checkmark")
          }
          .accessibilityLabel("补全当前文章图片文案")

          Divider()

          Button {
            store.imageWorkbench.optimizeSelectedDraftJPEGImages()
          } label: {
            Label("压缩 JPEG", systemImage: "photo.stack")
          }
          .accessibilityLabel("压缩当前文章 JPEG 图片")

          Button {
            store.imageWorkbench.convertSelectedDraftImagesToWebP()
          } label: {
            Label("转换 WebP", systemImage: "arrow.triangle.2.circlepath")
          }
          .accessibilityLabel("转换当前文章图片为 WebP")

          Button {
            store.imageWorkbench.optimizeSelectedDraftSVGImages()
          } label: {
            Label("优化 SVG", systemImage: "wand.and.stars")
          }
          .accessibilityLabel("优化当前文章 SVG 图片")

          Divider()

          Button {
            store.imageWorkbench.resizeSelectedDraftLargeImages()
          } label: {
            Label("缩放大图", systemImage: "arrow.down.right.and.arrow.up.left")
          }
          .accessibilityLabel("缩放当前文章大图")

          Button {
            store.imageWorkbench.cropSelectedDraftCoverImageForSocialPreview()
          } label: {
            Label("裁剪封面", systemImage: "crop")
          }
          .accessibilityLabel("裁剪当前文章封面图")
        } label: {
          Label("批量处理", systemImage: "slider.horizontal.3")
        }
        .disabled(store.selectedDraft == nil || store.imageWorkbench.isProcessingBatch)
        .accessibilityLabel("批量处理图片")
      }
    }
  }

  private var aiImageTextGenerationAvailability: AIImageTextGenerationAvailabilityPresentation {
    guard let draft = store.selectedDraft else {
      return AIImageTextGenerationAvailabilityPresentation(
        isEnabled: false,
        unavailableReason: "请先选择一篇文章"
      )
    }

    let profile = store.profile(for: draft)
    let targetCount = store.imageWorkbench.imageTextTargetCount(
      for: draft,
      report: store.imageWorkbench.cachedReport(for: draft)
    )
    return AIImageTextGenerationAvailabilityService.presentation(
      targetCount: targetCount,
      isGenerating: imageWorkbench.isGeneratingSuggestions,
      aiProviderConfig: profile.aiProviderConfig,
      aiTokenAvailability: imageWorkbench.aiTokenAvailability
    )
  }

  private var dropTargetOverlay: some View {
    RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      .fill(.thinMaterial)
      .overlay {
        VStack(spacing: 8) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 28))
          Text("拖入图片到当前文章")
            .font(.headline)
          Text("支持 jpg、png、webp、gif、svg、heic、tiff、avif")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
      }
      .padding(20)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("拖入图片到当前文章")
      .accessibilityHint("拖入图片文件到此处")
  }

  private var imageWorkbenchRefreshInput: ImageWorkbenchRefreshInput {
    ImageWorkbenchRefreshInput(
      report: store.selectedDraft.map { draft in
        ImageWorkbenchReportInputSignature(
          draft: draft,
          profile: store.profile(for: draft)
        )
      },
      siteSummary: ImageWorkbenchSiteSummaryInputSignature(
        drafts: store.visibleDrafts,
        profile: store.activeProfile
      )
    )
  }

  private func loadingCard(_ title: String) -> some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func siteWideSummary(_ summary: ImageWorkbenchSiteSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("当前 Profile 图片总览")
            .font(.headline)
          Text("\(summary.draftCount) 篇文章 · \(summary.imageCount) 张图片")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Menu {
          Button {
            store.imageWorkbench.fillMissingMetadataForVisibleDrafts()
          } label: {
            Label("补全 alt/caption", systemImage: "text.badge.checkmark")
          }

          Button {
            store.imageWorkbench.optimizeVisibleDraftJPEGImages()
          } label: {
            Label("压缩 JPEG", systemImage: "photo.stack")
          }

          Button {
            store.imageWorkbench.convertVisibleDraftImagesToWebP()
          } label: {
            Label("转换为 WebP", systemImage: "arrow.triangle.2.circlepath")
          }

          Button {
            store.imageWorkbench.optimizeVisibleDraftSVGImages()
          } label: {
            Label("优化 SVG", systemImage: "wand.and.stars")
          }

          Button {
            store.imageWorkbench.resizeVisibleDraftLargeImages()
          } label: {
            Label("缩放大图", systemImage: "arrow.down.right.and.arrow.up.left")
          }
        } label: {
          Label("批量处理", systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel("批量处理站点图片")
      }
      .disabled(store.imageWorkbench.isProcessingBatch)

      LazyVGrid(
        columns: [
          GridItem(.adaptive(minimum: 120), spacing: 12),
        ],
        spacing: 12
      ) {
        MetricTile(title: "总体积", value: ByteCountFormatter.string(fromByteCount: summary.totalByteSize, countStyle: .file), systemImage: "externaldrive")
        MetricTile(title: "缺 alt", value: "\(summary.missingAltTextCount)", systemImage: "text.quote")
        MetricTile(title: "源图缺失", value: "\(summary.missingSourceCount)", systemImage: "xmark.octagon")
        MetricTile(title: "重复图片", value: "\(summary.duplicateImageCount)", systemImage: "square.on.square")
        MetricTile(title: "可转 WebP", value: "\(summary.webPConvertibleCount)", systemImage: "arrow.triangle.2.circlepath")
        MetricTile(title: "可优化 SVG", value: "\(summary.optimizableSVGCount)", systemImage: "wand.and.stars")
        MetricTile(title: "可缩放", value: "\(summary.resizableImageCount)", systemImage: "arrow.down.right.and.arrow.up.left")
        MetricTile(title: "可压缩 JPEG", value: "\(summary.optimizableJPEGCount)", systemImage: "arrow.down.forward")
      }

      if !summary.draftSummaries.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("文章图片队列")
              .font(.callout.weight(.medium))
            Spacer()
            Text("\(summary.issueCount) 项")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          ForEach(summary.draftSummaries.prefix(6)) { draftSummary in
            Button {
              store.selectDraft(draftSummary.draftID)
            } label: {
              HStack(spacing: 10) {
                Image(systemName: draftSummary.errorCount > 0 ? "xmark.octagon" : (draftSummary.warningCount > 0 ? "exclamationmark.triangle" : "checkmark.circle"))
                  .foregroundStyle(draftSummary.errorCount > 0 ? .red : (draftSummary.warningCount > 0 ? .orange : .secondary))
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(draftSummary.draftTitle)
                    .lineLimit(1)
                  Text("\(draftSummary.imageCount) 张 · 缺 alt \(draftSummary.missingAltTextCount) · 重复 \(draftSummary.duplicateImageCount) · WebP \(draftSummary.webPConvertibleCount) · 缩放 \(draftSummary.resizableImageCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择文章 \(draftSummary.draftTitle)")
            .accessibilityValue("\(draftSummary.imageCount) 张图片，\(draftSummary.errorCount) 个错误，\(draftSummary.warningCount) 个警告")
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func aiImageTextSuggestionsSection(_ suggestions: [AIPublishingImageTextSuggestion]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("AI 图片文案建议", systemImage: "sparkles")
          .font(.headline)
        Spacer()
        Button {
          store.imageWorkbench.applyAISuggestions(suggestions)
        } label: {
          Label("全部应用", systemImage: "checkmark.circle")
        }
        .disabled(suggestions.isEmpty)
        .accessibilityLabel("应用全部 AI 图片文案建议")

        Button {
          store.imageWorkbench.clearAISuggestions()
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("清空 AI 图片文案建议")
        .accessibilityLabel("清空 AI 图片文案建议")
      }

      ForEach(suggestions) { suggestion in
        aiImageTextSuggestionRow(suggestion)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func aiImageTextSuggestionRow(_ suggestion: AIPublishingImageTextSuggestion) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "photo.badge.checkmark")
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 5) {
        Text(suggestion.filename)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        if !suggestion.altText.isEmpty {
          Text("alt: \(suggestion.altText)")
            .font(.caption)
            .textSelection(.enabled)
        }
        if !suggestion.caption.isEmpty {
          Text("caption: \(suggestion.caption)")
            .font(.caption)
            .textSelection(.enabled)
        }
        if !suggestion.reason.isEmpty {
          Text(suggestion.reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 8)

      Button {
        store.imageWorkbench.applyAISuggestion(suggestion)
      } label: {
        Image(systemName: "checkmark")
      }
      .buttonStyle(.borderless)
      .help("应用这条 AI 图片文案")
      .accessibilityLabel("应用 \(suggestion.filename) 的 AI 图片文案")
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 图片文案建议，\(suggestion.filename)")
  }

  @ViewBuilder
  private func metrics(report: ImageWorkbenchReport?) -> some View {
    let totalCount = report?.items.count ?? store.selectedDraft?.attachments.count ?? 0
    LazyVGrid(
      columns: [
        GridItem(.adaptive(minimum: 120), spacing: 12),
      ],
      spacing: 12
    ) {
      MetricTile(title: "图片", value: "\(totalCount)", systemImage: "photo")
      MetricTile(
        title: "总体积",
        value: ByteCountFormatter.string(fromByteCount: report?.totalByteSize ?? 0, countStyle: .file),
        systemImage: "externaldrive"
      )
      MetricTile(title: "缺 alt", value: "\(report?.missingAltTextCount ?? 0)", systemImage: "text.quote")
      MetricTile(title: "重复图片", value: "\(report?.duplicateImageCount ?? 0)", systemImage: "square.on.square")
      MetricTile(title: "可转 WebP", value: "\(report?.webPConvertibleCount ?? 0)", systemImage: "arrow.triangle.2.circlepath")
      MetricTile(title: "可优化 SVG", value: "\(report?.optimizableSVGCount ?? 0)", systemImage: "wand.and.stars")
      MetricTile(title: "可缩放", value: "\(report?.resizableImageCount ?? 0)", systemImage: "arrow.down.right.and.arrow.up.left")
      MetricTile(title: "可压缩 JPEG", value: "\(report?.optimizableJPEGCount ?? 0)", systemImage: "arrow.down.forward")
    }
  }

  @ViewBuilder
  private func issues(report: ImageWorkbenchReport?) -> some View {
    let visibleIssues = report?.issues.filter { $0.title != "还没有图片" } ?? []
    if !visibleIssues.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("图片发布检查")
            .font(.headline)
          Spacer()
          Text("\(visibleIssues.count) 项")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        ForEach(visibleIssues.prefix(8)) { issue in
          HStack(alignment: .top, spacing: 8) {
            SeverityBadge(severity: issue.severity)
              .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.title)
                .font(.callout.weight(.medium))
              Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  @ViewBuilder
  private func coverStatus(_ status: ImageCoverPublishStatus?) -> some View {
    if let status {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Label(status.state.localizedDisplayName, systemImage: status.state.systemImage)
            .font(.headline)
            .foregroundStyle(status.state.color)
          Spacer()
          if status.writesFrontMatter, let field = status.frontMatterFieldPath {
            Text(field)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          GridRow {
            Text("Front Matter")
              .foregroundStyle(.secondary)
            Text(status.frontMatterFieldPath ?? "不会写入")
              .font(.callout.monospaced())
              .textSelection(.enabled)
          }

          GridRow {
            Text("公开路径")
              .foregroundStyle(.secondary)
            Text(status.relativePublishPath ?? "未设置")
              .font(.callout.monospaced())
              .textSelection(.enabled)
          }

          GridRow {
            Text("仓库路径")
              .foregroundStyle(.secondary)
            Text(status.repositoryPath ?? "未设置")
              .font(.callout.monospaced())
              .textSelection(.enabled)
          }

          GridRow {
            Text("源文件")
              .foregroundStyle(.secondary)
            Text(status.sourceFilePath ?? "未记录")
              .font(.callout.monospaced())
              .lineLimit(2)
              .textSelection(.enabled)
          }
        }
        .font(.callout)

        if let filename = status.originalFilename {
          Label(filename, systemImage: status.fileExists ? "checkmark.circle" : "xmark.octagon")
            .font(.caption)
            .foregroundStyle(status.fileExists ? .green : .red)
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  private func binding(
    for attachmentID: UUID,
    keyPath: WritableKeyPath<DraftAttachment, String>
  ) -> Binding<String> {
    Binding(
      get: {
        store.selectedDraft?
          .attachments
          .first(where: { $0.id == attachmentID })?[keyPath: keyPath] ?? ""
      },
      set: { value in
        guard var draft = store.selectedDraft,
              let index = draft.attachments.firstIndex(where: { $0.id == attachmentID })
        else {
          return
        }
        draft.attachments[index][keyPath: keyPath] = value
        store.updateDraft(draft)
        Task { @MainActor in
          await store.refreshImageWorkbenchCachesInBackground(for: draft, force: true)
        }
      }
    )
  }

  private func insertImages(_ urls: [URL]) {
    let imageURLs = urls.filter(ImageFileSupport.isSupportedImageURL)
    guard !imageURLs.isEmpty else {
      store.imageWorkbench.setActionMessage("没有可导入的图片文件。")
      return
    }

    guard var draft = store.selectedDraft else {
      store.imageWorkbench.setActionMessage("请先选择一篇文章。")
      return
    }

    var markdownBlocks: [String] = []
    for url in imageURLs {
      let attachment = store.makeAttachment(from: url, draft: draft)
      draft.attachments.append(attachment)
      markdownBlocks.append("![\(attachment.altText)](\(attachment.relativePublishPath))")
    }
    draft.bodyMarkdown += "\n\n" + markdownBlocks.joined(separator: "\n")
    store.updateDraft(draft)
    Task { @MainActor in
      await store.refreshImageWorkbenchCachesInBackground(for: draft, force: true)
    }
    store.imageWorkbench.setActionMessage("已添加 \(imageURLs.count) 张图片。")
  }

  private func handleDroppedImageProviders(_ providers: [NSItemProvider]) -> Bool {
    let acceptedProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    guard !acceptedProviders.isEmpty else { return false }

    let dispatchGroup = DispatchGroup()
    let droppedURLs = ImageDropURLCollector()

    for (index, provider) in acceptedProviders.enumerated() {
      dispatchGroup.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        if let url = ImageDropURLDecoder.fileURL(from: item)?.standardizedFileURL {
          droppedURLs.append(url, at: index)
        }
        dispatchGroup.leave()
      }
    }

    dispatchGroup.notify(queue: .main) {
      insertImages(droppedURLs.orderedURLs())
    }

    return true
  }
}

private struct ImageWorkbenchRefreshInput: Hashable {
  let report: ImageWorkbenchReportInputSignature?
  let siteSummary: ImageWorkbenchSiteSummaryInputSignature
}

private enum ImageDropURLDecoder {
  static func fileURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL {
      return url
    }

    if let data = item as? Data {
      return URL(dataRepresentation: data, relativeTo: nil)
    }

    if let string = item as? String {
      if let url = URL(string: string), url.isFileURL {
        return url
      }
      return URL(fileURLWithPath: string)
    }

    return nil
  }
}

private final class ImageDropURLCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var indexedURLs: [(index: Int, url: URL)] = []

  func append(_ url: URL, at index: Int) {
    lock.lock()
    indexedURLs.append((index: index, url: url))
    lock.unlock()
  }

  func orderedURLs() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return indexedURLs
      .sorted { $0.index < $1.index }
      .map(\.url)
  }
}

private struct ImageWorkbenchRow: View {
  let attachment: DraftAttachment
  let item: ImageWorkbenchItem?
  let isCover: Bool
  @Binding var altText: String
  @Binding var caption: String
  let setCover: () -> Void
  let clearCover: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(attachment.originalFilename)
              .font(.headline)
              .lineLimit(1)
            if isCover {
              Label("封面", systemImage: "star.fill")
                .font(.caption)
                .foregroundStyle(WorkbenchTheme.warning)
            }
          }

          Text(attachment.relativePublishPath)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Text(ByteCountFormatter.string(fromByteCount: item?.byteSize ?? attachment.byteSize, countStyle: .file))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(item?.dimensions?.workbenchDimensionText ?? "未知尺寸")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 8) {
        ImageStatusPill(
          title: item?.fileExists == false ? "源图缺失" : "源图可用",
          systemImage: item?.fileExists == false ? "xmark.octagon" : "checkmark.circle",
          color: item?.fileExists == false ? .red : .green
        )
        ImageStatusPill(
          title: item?.isReferencedInMarkdown == true ? "正文已引用" : "正文未引用",
          systemImage: item?.isReferencedInMarkdown == true ? "link" : "link.badge.plus",
          color: item?.isReferencedInMarkdown == true ? .secondary : .orange
        )
        if item?.canOptimizeJPEG == true {
          ImageStatusPill(title: "可压缩", systemImage: "arrow.down.forward", color: .secondary)
        }
        if item?.canConvertToWebP == true {
          ImageStatusPill(title: "可转 WebP", systemImage: "arrow.triangle.2.circlepath", color: .secondary)
        }
        if item?.canOptimizeSVG == true {
          ImageStatusPill(title: "可优化 SVG", systemImage: "wand.and.stars", color: .secondary)
        }
        if item?.canResizeImage == true {
          ImageStatusPill(title: "可缩放", systemImage: "arrow.down.right.and.arrow.up.left", color: .secondary)
        }
        if let duplicateReferenceCount = item?.duplicateReferenceCount, duplicateReferenceCount > 0 {
          ImageStatusPill(title: "重复 \(duplicateReferenceCount)", systemImage: "square.on.square", color: .orange)
        }
        Spacer()
        Button {
          isCover ? clearCover() : setCover()
        } label: {
          Label(isCover ? "取消封面" : "设为封面", systemImage: isCover ? "star.slash" : "star")
        }
        .accessibilityLabel(isCover ? "取消设为封面" : "设为封面")
        .accessibilityHint("更新当前文章封面图片")
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
        GridRow {
          Text("仓库路径")
            .foregroundStyle(.secondary)
          Text(attachment.repositoryPath)
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }
        GridRow {
          Text("源文件")
            .foregroundStyle(.secondary)
          Text(attachment.sourceFilePath ?? "未记录")
            .font(.callout.monospaced())
            .lineLimit(2)
            .textSelection(.enabled)
        }
      }
      .font(.callout)

      VStack(alignment: .leading, spacing: 8) {
        TextField("Alt 文本", text: $altText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("图片 Alt 文本")
          .accessibilityValue(altText.isEmpty ? "未填写" : altText)
        TextField("Caption", text: $caption)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("图片 Caption")
          .accessibilityValue(caption.isEmpty ? "未填写" : caption)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片 \(attachment.originalFilename)")
    .accessibilityValue(imageAccessibilityValue)
  }

  private var imageAccessibilityValue: String {
    [
      isCover ? "封面" : nil,
      item?.fileExists == false ? "源图缺失" : "源图可用",
      item?.isReferencedInMarkdown == true ? "正文已引用" : "正文未引用",
      altText.isEmpty ? "Alt 未填写" : "Alt 已填写",
      caption.isEmpty ? "Caption 未填写" : "Caption 已填写",
    ]
    .compactMap { $0 }
    .joined(separator: "，")
  }
}

private struct ImageStatusPill: View {
  let title: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.thinMaterial, in: Capsule())
      .accessibilityLabel(title)
  }
}
