import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeSourceHistoryView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var knowledge: KnowledgeStore
  let documentID: UUID
  @State private var refreshPreview: KnowledgeSourceRefreshPreview?
  @State private var localRepairPreview: KnowledgeSourceRefreshPreview?
  @State private var isCheckingSource = false
  @State private var isPreparingLocalRepair = false
  @State private var refreshError: String?
  @State private var refreshResultMessage: String?
  @State private var pendingRestore: KnowledgeDocumentRevision?
  @State private var comparison: KnowledgeRevisionDifference?
  @State private var comparedRevisionID: UUID?
  @State private var isComparing = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("来源更新与版本历史", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
          .font(.headline)
        Spacer()
        Button("检查来源更新") { checkSource() }
          .disabled(document?.sourceURL == nil || isCheckingSource || knowledge.isBusy)
        Button("完成") { dismiss() }
      }
      .padding(14)
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          sourceSummary
          if let refreshPreview { refreshComparison(refreshPreview) }
          if let localRepairPreview { localRepairComparison(localRepairPreview) }
          Divider()
          revisionHistory
          if let comparison, let comparedRevisionID {
            Divider()
            revisionComparison(comparison, revisionID: comparedRevisionID)
          }
        }
        .padding(20)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 760, idealWidth: 920, minHeight: 620, idealHeight: 760)
    .task {
      knowledge.loadDocumentInsights(documentID: documentID)
    }
    .confirmationDialog(
      "恢复这个资料版本？",
      isPresented: Binding(
        get: { pendingRestore != nil },
        set: { if !$0 { pendingRestore = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("恢复所选版本") {
        guard let revision = pendingRestore else { return }
        pendingRestore = nil
        if knowledge.restoreRevision(revision.id, documentID: documentID) {
          comparison = nil
          comparedRevisionID = nil
        }
      }
      Button("取消", role: .cancel) { pendingRestore = nil }
    } message: {
      Text("旧版不会被删除；此操作只会把全文搜索、语义搜索和阅读正文切换到所选版本。")
    }
    .accessibilityIdentifier("knowledge-source-history")
  }

  private var document: KnowledgeDocument? {
    knowledge.documents.first { $0.id == documentID }
  }

  private var currentRevision: KnowledgeDocumentRevision? {
    guard let currentRevisionID = document?.currentRevisionID else { return nil }
    return knowledge.revisions.first { $0.id == currentRevisionID }
  }

  private var sourceSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(document?.title ?? "资料")
        .font(.title3.weight(.semibold))
      if let sourceURL = document?.sourceURL {
        Label(sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString, systemImage: "link")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else {
        Label("此资料没有可重新读取的来源，但仍可恢复已有版本。", systemImage: "link.badge.plus")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if isCheckingSource {
        ProgressView("正在下载并净化来源内容…")
          .controlSize(.small)
      }
      if let revision = currentRevision,
         revision.parserVersion < KnowledgeLibraryService.parserVersion {
        HStack(spacing: 8) {
          Label(
            "当前正文使用解析器 v\(revision.parserVersion)，可以在本机升级到 v\(KnowledgeLibraryService.parserVersion)。",
            systemImage: "wand.and.stars"
          )
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.warning)
          Spacer()
          Button("本地重新净化") { prepareLocalRepair() }
            .disabled(isPreparingLocalRepair || knowledge.isBusy)
        }
      }
      if isPreparingLocalRepair {
        ProgressView("正在读取本机网页归档并生成修复预览…")
          .controlSize(.small)
      }
      if let refreshResultMessage {
        Label(refreshResultMessage, systemImage: "checkmark.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityLabel("来源检查结果：\(refreshResultMessage)")
      }
      if let refreshError {
        HStack(spacing: 8) {
          Label(refreshError, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(WorkbenchTheme.warning)
          Spacer()
          Button("重试") { checkSource() }
            .disabled(isCheckingSource || knowledge.isBusy)
        }
        .accessibilityElement(children: .contain)
      }
    }
  }

  private func localRepairComparison(_ preview: KnowledgeSourceRefreshPreview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("本机正文净化预览", systemImage: "doc.text.magnifyingglass")
          .font(.headline)
        Spacer()
        Button("创建净化后的新版本") { applyLocalRepair(preview) }
          .workbenchProminentActionStyle()
          .disabled(knowledge.isBusy)
      }
      differenceSummary(preview.difference)
      comparisonColumns(
        leadingTitle: "当前资料库正文",
        leadingText: preview.difference.previousExcerpt,
        trailingTitle: "新版净化正文",
        trailingText: preview.difference.currentExcerpt
      )
      Text(
        preview.difference.hasChanges
          ? "将移除网页噪声并重建全文和本地语义索引；旧版本继续保留。"
          : "正文内容一致，但会升级解析器并重新生成全文和本地语义索引。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(14)
    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
  }

  private func refreshComparison(_ preview: KnowledgeSourceRefreshPreview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(
          preview.difference.hasChanges ? "发现来源变化" : "来源内容没有变化",
          systemImage: preview.difference.hasChanges ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        )
        .font(.headline)
        Spacer()
        Button("保存为新版本") { applyRefresh(preview) }
          .workbenchProminentActionStyle()
          .disabled(!preview.difference.hasChanges || knowledge.isBusy)
      }
      differenceSummary(preview.difference)
      comparisonColumns(
        leadingTitle: "资料库当前版",
        leadingText: preview.difference.previousExcerpt,
        trailingTitle: "来源新版",
        trailingText: preview.difference.currentExcerpt
      )
      Text("更新会创建新版本；原版本、标注和反向链接都会保留。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
  }

  private var revisionHistory: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("版本历史", systemImage: "clock")
        .font(.headline)
      if knowledge.revisions.isEmpty {
        ProgressView("正在读取版本历史…")
          .controlSize(.small)
      } else {
        ForEach(knowledge.revisions) { revision in
          HStack(spacing: 10) {
            Image(systemName: revision.id == document?.currentRevisionID ? "checkmark.circle.fill" : "clock")
              .foregroundStyle(revision.id == document?.currentRevisionID ? Color.accentColor : Color.secondary)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
              Text(revision.importedAt.formatted(date: .abbreviated, time: .standard))
                .font(.callout.weight(.medium))
              Text("解析器 v\(revision.parserVersion) · \(revision.normalizedContentHash.prefix(10))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if revision.id == document?.currentRevisionID {
              Text("当前")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            } else {
              Button("比较") { compare(revision) }
                .disabled(isComparing)
              Button("恢复") { pendingRestore = revision }
            }
          }
          .padding(.vertical, 5)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "版本 \(revision.importedAt.formatted(date: .abbreviated, time: .standard))"
              + (revision.id == document?.currentRevisionID ? "，当前版本" : "")
          )
        }
      }
    }
  }

  private func revisionComparison(
    _ difference: KnowledgeRevisionDifference,
    revisionID: UUID
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("历史版本与当前版本比较", systemImage: "rectangle.split.2x1")
        .font(.headline)
      differenceSummary(difference)
      comparisonColumns(
        leadingTitle: "所选历史版",
        leadingText: difference.previousExcerpt,
        trailingTitle: "当前版",
        trailingText: difference.currentExcerpt
      )
      Text("比较版本：\(revisionID.uuidString)")
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
    }
  }

  private func differenceSummary(_ difference: KnowledgeRevisionDifference) -> some View {
    HStack(spacing: 12) {
      Label("+\(difference.addedLineCount)", systemImage: "plus")
        .foregroundStyle(WorkbenchTheme.success)
      Label("−\(difference.removedLineCount)", systemImage: "minus")
        .foregroundStyle(WorkbenchTheme.warning)
      Text("\(difference.previousLineCount) → \(difference.currentLineCount) 行")
        .foregroundStyle(.secondary)
    }
    .font(.caption.monospacedDigit())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "新增 \(difference.addedLineCount) 行，删除 \(difference.removedLineCount) 行，"
        + "从 \(difference.previousLineCount) 行变为 \(difference.currentLineCount) 行"
    )
  }

  private func comparisonColumns(
    leadingTitle: String,
    leadingText: String,
    trailingTitle: String,
    trailingText: String
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      comparisonColumn(title: leadingTitle, text: leadingText)
      comparisonColumn(title: trailingTitle, text: trailingText)
    }
  }

  private func comparisonColumn(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
      ScrollView([.vertical, .horizontal]) {
        Text(text.isEmpty ? "（此处没有内容）" : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(9)
      }
      .frame(minHeight: 150, maxHeight: 230)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func checkSource() {
    isCheckingSource = true
    refreshError = nil
    refreshResultMessage = nil
    Task {
      defer { isCheckingSource = false }
      do {
        let preview = try await knowledge.makeSourceRefreshPreview(documentID: documentID)
        refreshPreview = preview
        refreshResultMessage = preview.difference.hasChanges
          ? "已发现来源变化，请预览后决定是否保存。"
          : "来源内容与当前版本一致。"
        EditorAccessibilityAnnouncementCenter.announce(
          refreshResultMessage ?? "来源检查完成。",
          priority: .medium
        )
      } catch {
        refreshPreview = nil
        refreshError = error.localizedDescription
        EditorAccessibilityAnnouncementCenter.announce(
          "来源检查失败：\(error.localizedDescription)",
          priority: .medium
        )
      }
    }
  }

  private func prepareLocalRepair() {
    isPreparingLocalRepair = true
    refreshError = nil
    Task {
      defer { isPreparingLocalRepair = false }
      guard let previews = await knowledge.localContentRepairPreviews(documentIDs: [documentID]),
            let preview = previews.first else {
        refreshError = knowledge.lastError ?? "这条资料没有可用的本机原始网页归档。"
        return
      }
      localRepairPreview = preview
      EditorAccessibilityAnnouncementCenter.announce(
        "本机正文净化预览已生成。",
        priority: .medium
      )
    }
  }

  private func applyLocalRepair(_ preview: KnowledgeSourceRefreshPreview) {
    Task {
      guard await knowledge.applyLocalContentRepairs([preview]) else { return }
      localRepairPreview = nil
      comparison = nil
      comparedRevisionID = nil
      EditorAccessibilityAnnouncementCenter.announce(
        "本机正文净化完成，已创建新版本并重建检索索引。",
        priority: .medium
      )
    }
  }

  private func applyRefresh(_ preview: KnowledgeSourceRefreshPreview) {
    Task {
      if await knowledge.applySourceRefresh(preview) {
        refreshPreview = nil
        comparison = nil
        comparedRevisionID = nil
      }
    }
  }

  private func compare(_ revision: KnowledgeDocumentRevision) {
    isComparing = true
    Task {
      defer { isComparing = false }
      do {
        comparison = try await knowledge.revisionDifference(
          documentID: documentID,
          revisionID: revision.id
        )
        comparedRevisionID = revision.id
      } catch {
        comparison = nil
        comparedRevisionID = nil
      }
    }
  }
}
