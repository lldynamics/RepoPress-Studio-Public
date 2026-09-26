import PublishingKnowledgeCore
import SwiftUI

struct KnowledgeImageBatchExportSheet: View {
  @ObservedObject var knowledge: KnowledgeStore
  let documentIDs: Set<UUID>
  @Binding var isPresented: Bool

  @State private var destinationDirectory: URL?
  @State private var removesSensitiveMetadata = false
  @State private var completedCount = 0
  @State private var totalCount = 0
  @State private var isExporting = false
  @State private var report: KnowledgeImageExportReport?
  @State private var exportFailure: String?

  private var selectedImageCount: Int {
    knowledge.documents.filter { documentIDs.contains($0.id) && $0.kind == .image }.count
  }

  private var selectedNonImageCount: Int {
    knowledge.documents.filter { documentIDs.contains($0.id) && $0.kind != .image }.count
  }

  private var exportMode: KnowledgeImageExportMode {
    removesSensitiveMetadata ? .privacySanitizedShareCopy : .originalFile
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("批量导出图片")
        .font(.title2.weight(.semibold))

      Text(selectionSummary)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 8) {
        Text("导出位置")
          .font(.headline)
        HStack(spacing: 10) {
          Text(destinationDirectory?.path ?? "尚未选择文件夹")
            .foregroundStyle(destinationDirectory == nil ? .secondary : .primary)
            .lineLimit(2)
            .textSelection(.enabled)
          Spacer(minLength: 8)
          Button("选择文件夹…") {
            Task { @MainActor in
              guard
                let selected =
                  await KnowledgeBatchExportSelectionPanel.chooseImageDestinationDirectory()
              else { return }
              destinationDirectory = selected
              report = nil
              exportFailure = nil
            }
          }
          .disabled(isExporting)
          .accessibilityIdentifier("knowledge-image-export-choose-directory")
        }
      }

      Toggle("创建移除敏感元数据的分享副本", isOn: $removesSensitiveMetadata)
        .toggleStyle(.checkbox)
        .disabled(isExporting)
        .onChange(of: removesSensitiveMetadata) { _, _ in
          report = nil
          exportFailure = nil
        }
        .accessibilityIdentifier("knowledge-image-export-remove-metadata")
      if removesSensitiveMetadata {
        Text("分享副本会移除 EXIF、GPS 等敏感元数据，可能重新编码；资料库中的原图不会被修改。")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Text("默认导出原图文件，按原始字节复制；资料库中的原图不会被修改。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if isExporting {
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: progressValue)
          Text("正在处理 \(completedCount) / \(max(totalCount, documentIDs.count)) 项…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("knowledge-image-export-progress")
      }

      if let report {
        imageExportReport(report)
      } else if let exportFailure {
        Text(exportFailure)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button(report == nil ? "取消" : "完成") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isExporting)
        .accessibilityIdentifier("knowledge-image-export-close")
        Button("导出图片") {
          beginExport()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(destinationDirectory == nil || selectedImageCount == 0 || isExporting)
        .accessibilityIdentifier("knowledge-image-export-confirm")
      }
    }
    .padding(24)
    .frame(minWidth: 560, idealWidth: 620)
    .accessibilityIdentifier("knowledge-image-batch-export-sheet")
  }

  private var selectionSummary: String {
    if selectedImageCount == 0 {
      return "所选资料中没有可导出的图片。"
    }
    if selectedNonImageCount == 0 {
      return "已选择 \(selectedImageCount) 张图片。"
    }
    return "已选择 \(selectedImageCount) 张图片；另有 \(selectedNonImageCount) 项非图片资料会跳过。"
  }

  private var progressValue: Double {
    guard totalCount > 0 else { return 0 }
    return min(1, Double(completedCount) / Double(totalCount))
  }

  @ViewBuilder
  private func imageExportReport(_ report: KnowledgeImageExportReport) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "已导出 \(report.exportedCount) 张，跳过 \(report.skippedCount) 项，失败 \(report.failedCount) 项。"
      )
      .font(.headline)
      if report.failedCount > 0 || report.skippedCount > 0 {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(report.items) { item in
              switch item.outcome {
              case .exported:
                EmptyView()
              case .skipped(let reason):
                Text("跳过“\(item.sourceName)”：\(reason)")
                  .foregroundStyle(.secondary)
              case .failed(let reason):
                Text("未导出“\(item.sourceName)”：\(reason)")
                  .foregroundStyle(.red)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("knowledge-image-export-result")
  }

  private func beginExport() {
    guard let destinationDirectory else { return }
    isExporting = true
    completedCount = 0
    totalCount = documentIDs.count
    report = nil
    exportFailure = nil
    let ids = documentIDs
    let mode = exportMode
    Task {
      let exportReport = await knowledge.exportImages(
        ids,
        to: destinationDirectory,
        mode: mode,
        progress: { completed, total in
          completedCount = completed
          totalCount = total
        }
      )
      isExporting = false
      report = exportReport
      if exportReport == nil {
        exportFailure = knowledge.lastError ?? "图片导出未完成。"
      }
    }
  }
}
