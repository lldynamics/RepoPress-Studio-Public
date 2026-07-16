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
        Label("\(preview.kind.localizedDisplayName)预览", systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(preview.application.localizedDisplayName)
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
        ("查找上一个", "⇧⌘G"),
        ("查找栏下一个 / 上一个", "Return / Shift-Return"),
        ("关闭查找栏", "Esc"),
        ("替换当前", "查找栏“替换”"),
        ("全部替换", "⌥⌘E"),
        ("插入图片", "⇧⌘I"),
        ("文章大纲", "⌥⌘O"),
        ("粘贴 URL 为链接", "选中文字后按 ⌘V"),
        ("粘贴截图", "⌘V")
      ]
    ),
    (
      "Markdown 智能编辑",
      [
        ("加粗", "⌘B"),
        ("斜体", "⌘I"),
        ("插入链接", "⌘K"),
        ("一级标题", "⌥⌘1"),
        ("二级标题", "⌥⌘2"),
        ("三级标题", "⌥⌘3"),
        ("续写列表或引用", "Return"),
        ("退出空列表项", "空项再按 Return"),
        ("增加列表层级", "Tab"),
        ("减少列表层级", "Shift-Tab")
      ]
    ),
    (
      "AI 与工具",
      [
        ("改写选中文本", "⌥⌘R"),
        ("打开 AI 对话", "通过发布控制台菜单进入"),
        ("复制上下文 Prompt", "通过发布控制台菜单进入")
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
