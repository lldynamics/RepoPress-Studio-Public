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
