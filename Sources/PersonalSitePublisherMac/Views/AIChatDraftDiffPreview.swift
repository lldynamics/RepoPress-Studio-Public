import PublishingWorkbenchCore
import SwiftUI

struct AIChatDraftDiffPreview: Identifiable {
  let id = UUID()
  let originalDraft: ArticleDraft
  let updatedDraft: ArticleDraft
  let citations: [KnowledgeCitation]

  var citationCount: Int { citations.count }
}

struct AIChatDraftDiffPreviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let preview: AIChatDraftDiffPreview
  let onApply: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("AI 修改预览", systemImage: "rectangle.split.2x1")
          .font(.headline)
        if preview.citationCount > 0 {
          Label("附带 \(preview.citationCount) 条资料引用", systemImage: "books.vertical")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(14)
      Divider()

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("行级差异", systemImage: "list.number")
            .font(.callout.weight(.semibold))
          Spacer()
          Text("−\(comparison.removedLineCount) 行 · +\(comparison.addedLineCount) 行")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        if comparison.bodyLineDiffs.isEmpty {
          ContentUnavailableView("正文没有变化", systemImage: "equal.circle")
        } else {
          ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(comparison.bodyLineDiffs) { line in
                AIChatLineDiffRow(line: line)
              }
            }
            .frame(minWidth: 780, alignment: .leading)
            .textSelection(.enabled)
          }
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(.separator, lineWidth: 1)
          }
        }
      }
      .padding(14)

      Divider()
      HStack {
        Text(changeSummary)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Text("应用前不会改动文章，可随时取消。")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("接受修改") {
          onApply()
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(minWidth: 820, idealWidth: 1_020, minHeight: 620, idealHeight: 760)
    .accessibilityLabel("AI 修改 Diff 预览")
  }

  private var comparison: DraftVersionComparison {
    DraftVersionComparisonService().compare(
      previous: preview.originalDraft,
      current: preview.updatedDraft,
      contextLineCount: 4
    )
  }

  private var changeSummary: String {
    let before = preview.originalDraft.bodyMarkdown.count
    let after = preview.updatedDraft.bodyMarkdown.count
    let delta = after - before
    return "修改前 \(before) 字符 · 修改后 \(after) 字符 · \(delta >= 0 ? "+" : "")\(delta)"
  }

}

private struct AIChatLineDiffRow: View {
  let line: DraftVersionLineDiff

  var body: some View {
    if line.kind == .skipped {
      Text("省略 \(line.skippedLineCount) 行未变化内容")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35))
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        lineNumber(line.previousLineNumber)
        lineNumber(line.currentLineNumber)
        Text(verbatim: prefix)
          .foregroundStyle(foregroundColor)
          .frame(width: 22, alignment: .center)
        Text(verbatim: line.text.isEmpty ? " " : line.text)
          .font(.callout.monospaced())
          .foregroundStyle(foregroundColor)
          .padding(.trailing, 12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 2)
      .background(backgroundColor)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
    }
  }

  private func lineNumber(_ number: Int?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.tertiary)
      .frame(width: 42, alignment: .trailing)
      .padding(.trailing, 7)
  }

  private var prefix: String {
    switch line.kind {
    case .removed: "−"
    case .added: "+"
    case .unchanged: " "
    case .skipped: "…"
    }
  }

  private var foregroundColor: Color {
    switch line.kind {
    case .removed: WorkbenchTheme.risk
    case .added: WorkbenchTheme.success
    case .unchanged, .skipped: .primary
    }
  }

  private var backgroundColor: Color {
    switch line.kind {
    case .removed: WorkbenchTheme.risk.opacity(0.10)
    case .added: WorkbenchTheme.success.opacity(0.10)
    case .unchanged, .skipped: .clear
    }
  }

  private var accessibilityLabel: String {
    switch line.kind {
    case .removed: "删除第 \(line.previousLineNumber ?? 0) 行：\(line.text)"
    case .added: "新增第 \(line.currentLineNumber ?? 0) 行：\(line.text)"
    case .unchanged: "未变化：\(line.text)"
    case .skipped: "省略 \(line.skippedLineCount) 行"
    }
  }
}
