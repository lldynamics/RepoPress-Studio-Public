import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SelectionEditPreviewPanel: View {
  let preview: AIPublishingSelectionEditPreview
  let onApply: (AIPublishingSelectionEditPreview) -> Void
  let onDiscard: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("\(preview.kind.displayName)预览", systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(preview.application.displayName)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(WorkbenchBackgroundStyle.badge, in: Capsule())
        if let modelSummary = preview.modelSummary {
          Text(modelSummary)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkbenchBackgroundStyle.badge, in: Capsule())
        }
        Spacer()
        Button {
          onDiscard()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("丢弃预览")
        .accessibilityLabel("丢弃 AI 预览")
      }

      HStack(alignment: .top, spacing: 10) {
        selectionPreviewColumn(
          title: preview.application == .replaceRange ? "原文" : "插入位置",
          text: preview.originalText.nilIfEmpty ?? "将在当前光标位置插入。"
        )
        selectionPreviewColumn(title: "AI 建议", text: preview.trimmedReplacementText)
      }

      HStack {
        Button {
          onApply(preview)
        } label: {
          Label("应用到选区", systemImage: "checkmark.circle")
        }
        .keyboardShortcut(.return, modifiers: [.command])

        Button {
          onDiscard()
        } label: {
          Label("丢弃", systemImage: "xmark.circle")
        }

        Spacer()
      }
    }
    .padding(10)
    .frame(maxWidth: 720)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .shadow(radius: 10, y: 3)
  }

  private func selectionPreviewColumn(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        Text(text)
          .font(.caption)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 150)
      .padding(8)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MarkdownShortcutHelpPanel: View {
  @Environment(\.dismiss) private var dismiss

  private let shortcutGroups: [(String, [(String, String)])] = [
    (
      "编辑",
      [
        ("查找", "⌘F"),
        ("查找下一个", "⌘G"),
        ("替换当前", "⌘E"),
        ("全部替换", "⌥⌘E"),
        ("插入图片", "⇧⌘I")
      ]
    ),
    (
      "AI 与工具",
      [
        ("改写选中文本", "⌥⌘R"),
        ("打开 AI 对话", "通过发布控制台菜单进入"),
        ("复制上下文 Prompt", "通过发布控制台菜单进入")
      ]
    ),
    (
      "会话历史（仅内存）",
      [
        ("查看会话历史", "⌥⌘Z"),
        ("撤销会话快照", "⇧⌥⌘Z"),
        ("恢复会话快照", "⌃⇧⌥⌘Z")
      ]
    )
  ]

  var body: some View {
    NavigationStack {
      Form {
        ForEach(shortcutGroups.indices, id: \.self) { groupIndex in
          let group = shortcutGroups[groupIndex]
          Section(group.0) {
            ForEach(group.1.indices, id: \.self) { row in
              let shortcut = group.1[row]
              HStack {
                Text(shortcut.0)
                  .font(.body)
                Spacer()
                Text(shortcut.1)
                  .font(.body.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("快捷键说明")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            dismiss()
          }
        }
      }
    }
    .frame(width: 430, height: 360)
  }
}

struct MarkdownRevisionHistoryPanel: View {
  let revisions: [MarkdownEditorRevisionSnapshot]
  let currentIndex: Int
  let onRestore: (Int) -> Void
  let onResetToCurrent: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("#\(revisions.count - index)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Spacer()
              Text(revision.createdAt.workbenchShortText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(revision.previewTitle)
              .font(.caption)
              .lineLimit(1)

            Text("\(revision.characterCount) 字符 · \(revision.wordCount) 词 · \(revision.lineCount) 行")
              .font(.caption2)
              .foregroundStyle(.secondary)

            if index != currentIndex {
              Button("恢复") {
                onRestore(index)
                dismiss()
              }
              .buttonStyle(.bordered)
              .font(.caption)
              .padding(.top, 2)
            } else {
              Text("当前会话快照")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
            }
          }
          .padding(.vertical, 4)
        }
      }
      .navigationTitle("会话历史（仅本次打开）")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("仅保留当前会话快照") {
            onResetToCurrent()
          }
          .disabled(revisions.count <= 1)
          .help("清空本次会话的内存快照；不会影响已保存的数据")
        }

        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            dismiss()
          }
        }
      }
    }
    .frame(width: 520, height: 420)
  }
}

struct MarkdownEditorRevisionSnapshot: Identifiable {
  let id: UUID
  let createdAt: Date
  let label: String?
  let body: String
  let selectedRange: NSRange
  let characterCount: Int
  let wordCount: Int
  let lineCount: Int

  var previewTitle: String {
    let prefix = label ?? "会话快照"
    let preview = body.trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(50)
    if preview.isEmpty {
      return "\(prefix)：空内容"
    }
    return "\(prefix)：\(preview)"
  }
}

struct MarkdownOutlineSidebar: View {
  let items: [MarkdownOutlineItem]
  let selectedRange: NSRange
  let onSelect: (MarkdownOutlineItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("大纲", systemImage: "list.bullet.indent")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(items.count)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)

      Divider()

      if items.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "text.alignleft")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("暂无 H2/H3")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(items, id: \.id) { item in
          Button {
            onSelect(item)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: item.level == 2 ? "h.square" : "textformat.size.smaller")
                .foregroundStyle(.secondary)
                .frame(width: 16)

              Text(item.title)
                .lineLimit(1)
                .padding(.leading, item.level == 3 ? 12 : 0)

              Spacer(minLength: 4)

              if item.publicRiskSummary.errorCount > 0 {
                Image(systemName: "xmark.octagon.fill")
                  .foregroundStyle(.red)
              } else if item.publicRiskSummary.warningCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(isSelected(item) ? Color.accentColor : Color.primary)
          .help(item.publicRiskSummary.statusTitle)
          .accessibilityLabel("跳转到文章小节")
          .accessibilityValue(item.title)
        }
        .listStyle(.sidebar)
      }
    }
    .background(.bar)
  }

  private func isSelected(_ item: MarkdownOutlineItem) -> Bool {
    selectedRange.location >= item.sectionLocation
      && selectedRange.location < item.sectionLocation + item.sectionLength
  }
}

struct PublishingReviewPane: View {
  let draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        readinessSummary
        issueList
        repositoryComparison
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.bar)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("发布整理")
        .font(.title3.weight(.semibold))
      Text(store.profile(for: draft).markdownPath(for: draft))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)
    }
  }

  private var readinessSummary: some View {
    let package = store.publishingPackage(for: draft)
    let preview = store.localPublishPreview(for: draft)
    let imageReport = store.imageWorkbenchReport(for: draft)
    let riskSummary = store.publicRiskSummary(for: draft)

    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
      MetricTile(title: "发布文件", value: "\(package.files.count)", systemImage: "shippingbox")
      MetricTile(title: "待写入", value: "\(preview.changedFileDiffs.count)", systemImage: "arrow.left.arrow.right")
      MetricTile(title: "公开风险", value: "\(riskSummary.issueCount)", systemImage: "lock.shield")
      MetricTile(title: "缺 alt", value: "\(imageReport.missingAltTextCount)", systemImage: "text.quote")
    }
  }

  private var issueList: some View {
    let issues = store.preflightIssues(for: draft).filter { $0.severity != .info }

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("发布清单")
          .font(.headline)
        Spacer()
        Button {
          store.focusDraft(draft.id, section: .contentHealth)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("刷新发布检查")
        .accessibilityLabel("刷新发布检查")
      }

      if issues.isEmpty {
        Label("当前没有阻塞项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(issues.prefix(6)) { issue in
          VStack(alignment: .leading, spacing: 4) {
            SeverityBadge(severity: issue.severity)
            Text(issue.title)
              .font(.callout.weight(.medium))
            Text(issue.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          Divider()
        }
      }
    }
  }

  private var repositoryComparison: some View {
    let comparison = store.draftComparisonContent(for: draft)
    let preview = store.localPublishPreview(for: draft)
    let markdownDiff = preview.fileDiffs.first { $0.kind == .markdown }?.lineDiff

    return VStack(alignment: .leading, spacing: 10) {
      Text("仓库对照")
        .font(.headline)

      Label(comparison.repositoryPath, systemImage: "doc.text.magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      if let content = comparison.preferredContent {
        Text(comparison.preferredTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(content)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(24)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      } else if let markdownDiff {
        Text("仓库版本暂不可读，显示本地 diff。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(markdownDiff)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(24)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      } else {
        Label("未找到本地或远端版本。", systemImage: "doc.badge.questionmark")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
