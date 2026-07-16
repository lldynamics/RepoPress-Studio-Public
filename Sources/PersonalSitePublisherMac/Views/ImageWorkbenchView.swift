import PublishingWorkbenchCore
import SwiftUI

struct ImageWorkbenchView: View {
  let store: WorkbenchStore
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade

  init(store: WorkbenchStore) {
    self.store = store
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        batchStatus

        if let summary = store.cachedImageWorkbenchSiteSummary {
          siteWideSummary(summary)
        } else {
          loadingCard
        }
      }
      .padding(20)
    }
    .accessibilityLabel("全站图片优化")
    .task(id: refreshInput) {
      await store.refreshImageWorkbenchSiteSummaryInBackground()
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

      Button {
        Task { @MainActor in
          await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
        }
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .controlSize(.small)
      .accessibilityLabel("刷新全站图片扫描")
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
        ProgressView(value: progress.fractionCompleted)
          .frame(maxWidth: 220)
        Text(progress.operation.progressTitle)
        Text("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") {
          imageWorkbench.cancelBatchProcessing()
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("全站图片处理进度")
      .accessibilityValue("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
    }
  }

  private func siteWideSummary(_ summary: ImageWorkbenchSiteSummary) -> some View {
    let metrics = issueMetrics(for: summary)
    let affectedDrafts = summary.draftSummaries.filter { $0.issueCount > 0 }

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
        if summary.imageCount > 0 {
          optimizationMenu
        }
      }

      if summary.imageCount == 0 {
        VStack(alignment: .leading, spacing: 6) {
          Label("还没有可扫描的图片", systemImage: "photo.on.rectangle.angled")
            .font(.callout.weight(.medium))
          Text("在文章中添加图片后，这里会显示缺失元数据、重复文件和可优化格式。")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            if store.selectedDraftID == nil {
              store.createDraft()
            } else {
              store.selectSection(.writing)
            }
          } label: {
            Label(
              store.selectedDraftID == nil ? "新建文章并插图" : "前往写作并插图",
              systemImage: "photo.badge.plus"
            )
          }
          .controlSize(.small)
          .padding(.top, 2)
        }
        .padding(.vertical, 10)
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

          ForEach(affectedDrafts.prefix(20)) { draftSummary in
            Button {
              guard store.focusDraft(draftSummary.draftID, section: .images) else { return }
              store.setInspectorPresented(true)
            } label: {
              HStack(spacing: 10) {
                Image(systemName: draftSummary.errorCount > 0 ? "xmark.octagon" : "exclamationmark.triangle")
                  .foregroundStyle(draftSummary.errorCount > 0 ? .red : .orange)
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(draftSummary.draftTitle)
                    .lineLimit(1)
                  Text(issueSummary(for: draftSummary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                Text("\(draftSummary.issueCount)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
                Image(systemName: "sidebar.right")
                  .foregroundStyle(.tertiary)
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 Inspector 查看 \(draftSummary.draftTitle) 的图片")
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var optimizationMenu: some View {
    Menu {
      Button {
        imageWorkbench.fillMissingMetadataForVisibleDrafts()
      } label: {
        Label("补全 alt/caption", systemImage: "text.badge.checkmark")
      }

      Divider()

      Button {
        imageWorkbench.optimizeVisibleDraftJPEGImages()
      } label: {
        Label("压缩 JPEG", systemImage: "photo.stack")
      }

      Button {
        imageWorkbench.convertVisibleDraftImagesToWebP()
      } label: {
        Label("转换为 WebP", systemImage: "arrow.triangle.2.circlepath")
      }

      Button {
        imageWorkbench.optimizeVisibleDraftSVGImages()
      } label: {
        Label("优化 SVG", systemImage: "wand.and.stars")
      }

      Button {
        imageWorkbench.resizeVisibleDraftLargeImages()
      } label: {
        Label("缩放大图", systemImage: "arrow.down.right.and.arrow.up.left")
      }
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

  private var refreshInput: ImageWorkbenchSiteSummaryInputSignature {
    ImageWorkbenchSiteSummaryInputSignature(
      drafts: store.visibleDrafts,
      profile: store.activeProfile
    )
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
}

private struct ImageOptimizationMetric: Identifiable {
  let title: String
  let value: Int
  let systemImage: String

  var id: String { title }
}
