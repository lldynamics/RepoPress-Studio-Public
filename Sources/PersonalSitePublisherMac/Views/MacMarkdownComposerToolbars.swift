import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  let markdownPath: String
  let lastSaveStatus: String
  let hasUnsavedChanges: Bool
  let editorDisplayMode: EditorDisplayMode
  let isSelectionAIActionRunning: Bool
  let onSetEditorDisplayMode: (EditorDisplayMode) -> Void
  let onShowFindReplace: () -> Void
  let onShowShortcutHelp: () -> Void
  let onShowRevisionHistory: () -> Void
  let onOpenAIContextInspector: () -> Void
  let writingAIActionMenuItems: [AIPublishingActionMenuItem]
  let publishingAIActionMenuItems: [AIPublishingActionMenuItem]
  let distributionAIActionMenuItems: [AIPublishingActionMenuItem]
  let maintenanceAIActionMenuItems: [AIPublishingActionMenuItem]
  let additionalSelectionAIActionMenuItems: [AIPublishingActionMenuItem]
  let selectionAIActionAvailability: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let articleAIActionAvailability: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let onPerformSelectionAIAction: (AIPublishingActionKind) -> Void
  let onPerformArticleAIAction: (AIPublishingActionKind) -> Void
  let onPasteAIPromptToClipboard: () -> Void
  let onRewriteSelection: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        TextField("文章标题", text: $title)
          .textFieldStyle(.plain)
          .font(.headline)
          .lineLimit(1)
          .accessibilityLabel("文章标题")
          .accessibilityValue(title.nilIfEmpty ?? "未命名文章")

        Text(markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(minWidth: 220, idealWidth: 320, maxWidth: 460, alignment: .leading)

      Spacer()

      HStack(spacing: 5) {
        if hasUnsavedChanges {
          Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
        }
        if hasUnsavedChanges {
          Text(lastSaveStatus)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
        } else {
          Text(lastSaveStatus)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .accessibilityLabel("保存状态")
      .accessibilityValue(lastSaveStatus)

      editorDisplayModeControl

      Menu {
        Button {
          onShowFindReplace()
        } label: {
          Label("查找与替换", systemImage: "magnifyingglass")
        }

        Button {
          onShowShortcutHelp()
        } label: {
          Label("快捷键说明", systemImage: "keyboard")
        }

        Button {
          onShowRevisionHistory()
        } label: {
          Label("会话历史", systemImage: "clock.arrow.circlepath")
        }

        Divider()

        Button {
          onOpenAIContextInspector()
        } label: {
          Label("打开 AI 对话", systemImage: "sparkles")
        }

        Divider()

        Menu {
          ForEach(writingAIActionMenuItems) { item in
            articleAIActionButton(item)
          }
        } label: {
          Label("写作生成", systemImage: "square.and.pencil")
        }

        Menu {
          ForEach(publishingAIActionMenuItems) { item in
            articleAIActionButton(item)
          }
        } label: {
          Label("发布检查", systemImage: "checkmark.shield")
        }

        Menu {
          ForEach(distributionAIActionMenuItems) { item in
            articleAIActionButton(item)
          }
        } label: {
          Label("分发素材", systemImage: "megaphone")
        }

        Menu {
          ForEach(maintenanceAIActionMenuItems) { item in
            articleAIActionButton(item)
          }
        } label: {
          Label("内容维护", systemImage: "wrench.and.screwdriver")
        }

        Divider()

        Button {
          onRewriteSelection()
        } label: {
          Label("改写选中文本", systemImage: "wand.and.stars")
        }
        .disabled(!selectionAIActionAvailability(.rewriteSelection).isEnabled)
        .help(selectionAIActionAvailability(.rewriteSelection).unavailableReason ?? "改写选中文本")

        ForEach(additionalSelectionAIActionMenuItems) { item in
          selectionAIActionButton(item)
        }

        Button {
          onPasteAIPromptToClipboard()
        } label: {
          Label("复制上下文 Prompt", systemImage: "doc.on.doc")
        }
      } label: {
        Label("更多", systemImage: "ellipsis.circle")
      }
      .help("查找、快捷键、会话历史与 AI 操作")
      .accessibilityLabel("更多编辑器操作")
      .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var editorDisplayModeControl: some View {
    HStack(spacing: 2) {
      ForEach(EditorDisplayMode.allCases) { mode in
        Button {
          onSetEditorDisplayMode(mode)
        } label: {
          Image(systemName: mode.systemImage)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 22)
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(editorDisplayMode == mode ? Color.accentColor : Color.secondary)
        .background(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .fill(editorDisplayMode == mode ? Color.accentColor.opacity(WorkbenchOpacity.accentBackground) : Color.clear)
        )
        .accessibilityLabel("编辑器模式：\(mode.displayName)")
        .accessibilityValue(editorDisplayMode == mode ? "已选择" : "未选择")
        .help("切换到\(mode.displayName)模式")
      }
    }
    .padding(2)
    .frame(width: 92, height: 28)
    .background(WorkbenchBackgroundStyle.badge, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
  }

  private func articleAIActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    let availability = articleAIActionAvailability(item.kind)
    return Button {
      onPerformArticleAIAction(item.kind)
    } label: {
      Label(item.kind.displayName, systemImage: item.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? item.kind.displayName)
  }

  private func selectionAIActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    let availability = selectionAIActionAvailability(item.kind)
    return Button {
      onPerformSelectionAIAction(item.kind)
    } label: {
      Label(item.kind.displayName, systemImage: item.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? item.kind.displayName)
  }
}

struct MacMarkdownFormattingToolbar: View {
  let characterCount: Int
  let wordCount: Int
  let lineCount: Int
  let readingMinutes: Int
  let onApplyHeading: (Int) -> Void
  let onWrapSelection: (String, String, String) -> Void
  let onPrefixCurrentLine: (String) -> Void
  let onInsertCodeBlock: () -> Void
  let onInsertTable: () -> Void
  let onInsertHorizontalRule: () -> Void
  let onInsertLink: () -> Void
  let onInsertImage: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Menu {
        Button {
          onApplyHeading(1)
        } label: {
          Label("一级标题", systemImage: "h.square")
        }

        Button {
          onApplyHeading(2)
        } label: {
          Label("二级标题", systemImage: "h.square")
        }

        Button {
          onApplyHeading(3)
        } label: {
          Label("三级标题", systemImage: "textformat.size.smaller")
        }
      } label: {
        toolbarIcon("number")
      }
      .help("标题")
      .accessibilityLabel("标题格式")

      Divider()
        .frame(height: 18)

      Button {
        onWrapSelection("**", "**", "粗体")
      } label: {
        toolbarIcon("bold")
      }
      .help("粗体")
      .accessibilityLabel("粗体")

      Button {
        onWrapSelection("*", "*", "斜体")
      } label: {
        toolbarIcon("italic")
      }
      .help("斜体")
      .accessibilityLabel("斜体")

      Button {
        onWrapSelection("`", "`", "code")
      } label: {
        toolbarIcon("chevron.left.forwardslash.chevron.right")
      }
      .help("行内代码")
      .accessibilityLabel("行内代码")

      Divider()
        .frame(height: 18)

      Menu {
        Button {
          onPrefixCurrentLine("> ")
        } label: {
          Label("引用", systemImage: "quote.opening")
        }

        Button {
          onPrefixCurrentLine("- ")
        } label: {
          Label("无序列表", systemImage: "list.bullet")
        }

        Button {
          onPrefixCurrentLine("1. ")
        } label: {
          Label("有序列表", systemImage: "list.number")
        }

        Button {
          onPrefixCurrentLine("- [ ] ")
        } label: {
          Label("任务列表", systemImage: "checklist")
        }

        Divider()

        Button {
          onInsertCodeBlock()
        } label: {
          Label("代码块", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        Button {
          onInsertTable()
        } label: {
          Label("表格", systemImage: "rectangle.grid.2x2")
        }

        Button {
          onInsertHorizontalRule()
        } label: {
          Label("分隔线", systemImage: "minus")
        }
      } label: {
        toolbarIcon("text.alignleft")
      }
      .help("块级格式")
      .accessibilityLabel("块级格式")

      Button {
        onInsertLink()
      } label: {
        toolbarIcon("link")
      }
      .help("链接")
      .accessibilityLabel("链接")

      Button {
        onInsertImage()
      } label: {
        toolbarIcon("photo.badge.plus")
      }
      .help("插图")
      .accessibilityLabel("插图")

      Spacer()

      Text("\(characterCount) 字符 · \(wordCount) 词 · \(lineCount) 行 · 约 \(readingMinutes) min")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel("文章统计")
        .accessibilityValue("\(characterCount) 字符，\(wordCount) 词，\(lineCount) 行，预计阅读 \(readingMinutes) 分钟")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func toolbarIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .frame(width: 22, height: 22)
  }
}
