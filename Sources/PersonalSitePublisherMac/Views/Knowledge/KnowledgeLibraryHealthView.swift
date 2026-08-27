import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeLibraryHealthView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var state: KnowledgeLibraryHealthFeatureFacade
  @State private var repairPreviews: [KnowledgeSourceRefreshPreview] = []
  @State private var didAnalyzeRepairs = false

  init(knowledge: KnowledgeStore) {
    _state = StateObject(
      wrappedValue: KnowledgeLibraryHealthFeatureFacade(store: knowledge)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label("资料库健康", systemImage: "checkmark.shield")
          .font(.headline)
        Spacer()
        Button("重新检查") { Task { await refresh() } }
          .disabled(state.isLoading || state.isBusy)
        Button("完成") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let health = state.healthSnapshot {
            healthSummary(health)
            repairSection(health)
            semanticSection(health)
          } else if state.isLoading {
            ProgressView("正在检查解析器、正文质量和本地语义索引…")
              .frame(maxWidth: .infinity, minHeight: 180)
          } else {
            ContentUnavailableView(
              "无法读取健康状态",
              systemImage: "exclamationmark.triangle",
              description: Text(state.lastError ?? "请重新检查资料库。")
            )
          }
        }
        .padding(20)
        .frame(maxWidth: 880, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 620, idealHeight: 760)
    .task { await refresh() }
    .accessibilityIdentifier("knowledge-library-health")
  }

  private func healthSummary(_ health: KnowledgeLibraryHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(
          health.needsAttention ? "发现可修复项目" : "资料库状态良好",
          systemImage: health.needsAttention ? "wrench.and.screwdriver" : "checkmark.circle.fill"
        )
        .font(.title3.weight(.semibold))
        .foregroundStyle(health.needsAttention ? WorkbenchTheme.warning : WorkbenchTheme.success)
        Spacer()
        Text("当前解析器 v\(health.currentParserVersion)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        metric("资料", value: health.documentCount, systemImage: "books.vertical")
        metric("检索片段", value: health.indexedChunkCount, systemImage: "text.quote")
        metric("旧版资料", value: health.outdatedParserDocumentCount, systemImage: "clock.arrow.circlepath")
        metric("低质量片段", value: health.lowQualityChunkCount, systemImage: "line.3.horizontal.decrease.circle")
      }
    }
    .padding(15)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
    .accessibilityElement(children: .contain)
  }

  private func metric(_ title: String, value: Int, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value.formatted())
        .font(.title3.weight(.semibold).monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func repairSection(_ health: KnowledgeLibraryHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("网页正文净化", systemImage: "doc.text.magnifyingglass")
          .font(.headline)
        Spacer()
        Button(didAnalyzeRepairs ? "重新分析" : "分析并预览") {
          Task { await analyzeRepairs() }
        }
        .disabled(health.locallyRepairableDocumentCount == 0 || state.isBusy)
      }
      Text("使用资料库内保存的原始网页归档重新提取正文，不联网、不覆盖旧版本；完成后同时重建全文和本地语义索引。")
        .font(.callout)
        .foregroundStyle(.secondary)

      if health.outdatedParserDocumentCount > health.locallyRepairableDocumentCount {
        Label(
          "有 \(health.outdatedParserDocumentCount - health.locallyRepairableDocumentCount) 条旧版资料缺少可用网页归档，需要重新导入。",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
      }

      if didAnalyzeRepairs && repairPreviews.isEmpty {
        Label("没有可在本机重新净化的网页资料。", systemImage: "checkmark.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ForEach(repairPreviews, id: \.documentID) { preview in
        repairPreviewRow(preview)
      }

      if !repairPreviews.isEmpty {
        HStack {
          Text("修复会为每条资料创建新版本，旧版本仍可恢复。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("修复 \(repairPreviews.count) 条资料") {
            Task { await applyRepairs() }
          }
          .workbenchProminentActionStyle()
          .disabled(state.isBusy)
        }
      }
    }
  }

  private func repairPreviewRow(_ preview: KnowledgeSourceRefreshPreview) -> some View {
    let documentTitle = state.documentTitle(for: preview.documentID) ?? "网页资料"
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(documentTitle)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(documentTitle)
        Spacer()
        Text("v\(preview.currentRevision.parserVersion) → v\(KnowledgeLibraryService.parserVersion)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      if preview.difference.hasChanges {
        HStack(spacing: 6) {
          if preview.difference.addedLineCount > 0 {
            Text("+\(preview.difference.addedLineCount)")
              .font(.workbenchMetadata.monospacedDigit().weight(.semibold))
              .foregroundStyle(WorkbenchTheme.success)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkbenchTheme.success.opacity(0.12), in: Capsule())
          }
          if preview.difference.removedLineCount > 0 {
            Text("−\(preview.difference.removedLineCount)")
              .font(.workbenchMetadata.monospacedDigit().weight(.semibold))
              .foregroundStyle(WorkbenchTheme.risk)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkbenchTheme.risk.opacity(0.12), in: Capsule())
          }
          Text(String(localized: "行变化"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text(String(localized: "正文内容一致；仍会升级解析器版本并重新生成索引。"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let warning = preview.importPreview.candidates.first?.warnings.last {
        Text(warning)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(11)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .combine)
  }

  private func semanticSection(_ health: KnowledgeLibraryHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("本地语义索引", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.headline)
        Spacer()
        Button("重建全部语义索引") {
          Task { await state.rebuildAllSemanticIndex() }
        }
        .disabled(!state.hasDocuments || state.isBusy)
      }

      if state.isBusy {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(String(localized: "正在构建本地向量并更新语义索引…"))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      } else {
        Text(
          health.semanticRepairChunkCount == 0
            ? "当前片段均有可用的本地语义向量。"
            : "有 \(health.semanticRepairChunkCount) 个片段的向量缺失、维度不匹配或指向旧版本。"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func refresh() async {
    await state.refreshLibraryHealth()
  }

  private func analyzeRepairs() async {
    didAnalyzeRepairs = true
    repairPreviews = await state.localContentRepairPreviews() ?? []
  }

  private func applyRepairs() async {
    guard await state.applyLocalContentRepairs(repairPreviews) else { return }
    repairPreviews = []
    didAnalyzeRepairs = true
  }
}
