import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  let markdownPath: String
  let lastSaveStatus: String
  let hasUnsavedChanges: Bool
  let editorDisplayMode: EditorDisplayMode
  let isSelectionAIActionRunning: Bool
  @Binding var isOutlinePresented: Bool
  let outlineItems: [MarkdownOutlineItem]
  let onSetEditorDisplayMode: (EditorDisplayMode) -> Void
  let onShowFindReplace: () -> Void
  let onShowOutline: () -> Void
  let onSelectOutlineItem: (MarkdownOutlineItem) -> Void
  let onShowShortcutHelp: () -> Void
  let onOpenAIContextInspector: () -> Void
  let recommendedAIActionMenuItems: [AIPublishingActionMenuItem]
  let moreAIActionMenuItems: [AIPublishingActionMenuItem]
  let isSelectionAIAction: (AIPublishingActionKind) -> Bool
  let selectionAIActionAvailability: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let articleAIActionAvailability: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let onPerformSelectionAIAction: (AIPublishingActionKind) -> Void
  let onPerformArticleAIAction: (AIPublishingActionKind) -> Void
  let onPasteAIPromptToClipboard: () -> Void

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
            .foregroundStyle(WorkbenchTheme.warning)
            .accessibilityHidden(true)
        }
        if hasUnsavedChanges {
          Text(lastSaveStatus)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
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

      expandedEditorActions
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var expandedEditorActions: some View {
    HStack(spacing: 2) {
      Button {
        onShowFindReplace()
      } label: {
        editorActionIcon("magnifyingglass")
      }
      .help("查找与替换")
      .accessibilityLabel("查找与替换")

      Button {
        onShowOutline()
      } label: {
        editorActionIcon("list.bullet.indent")
      }
      .keyboardShortcut("o", modifiers: [.command, .option])
      .help("文章大纲（⌥⌘O）")
      .accessibilityLabel("文章大纲")
      .accessibilityIdentifier("markdown-outline-button")
      .popover(isPresented: $isOutlinePresented, arrowEdge: .top) {
        MarkdownOutlinePopover(
          items: outlineItems,
          onSelect: onSelectOutlineItem
        )
      }

      Button {
        onShowShortcutHelp()
      } label: {
        editorActionIcon("keyboard")
      }
      .help("快捷键说明")
      .accessibilityLabel("快捷键说明")

      Divider()
        .frame(height: 18)

      Menu {
        ForEach(recommendedAIActionMenuItems) { item in
          aiActionButton(item)
        }

        Divider()

        Menu("更多指令") {
          ForEach(AIPublishingQuickPromptGroup.allCases) { group in
            let groupItems = moreAIActionMenuItems.filter {
              $0.kind.promptLibraryGroup == group
            }
            if !groupItems.isEmpty {
              Menu {
                ForEach(groupItems) { item in
                  aiActionButton(item)
                }
              } label: {
                Label(aiActionGroupTitle(group), systemImage: group.systemImage)
              }
            }
          }

          Divider()

          Button {
            onOpenAIContextInspector()
          } label: {
            Label("打开 AI 对话", systemImage: "bubble.left.and.text.bubble.right")
          }

          Button {
            onPasteAIPromptToClipboard()
          } label: {
            Label("复制上下文 Prompt", systemImage: "doc.on.doc")
          }
        }
      } label: {
        editorActionIcon("sparkles")
      }
      .help("AI 推荐指令")
      .accessibilityLabel("AI 推荐指令")
      .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    }
    .buttonStyle(.borderless)
    .accessibilityElement(children: .contain)
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
        .foregroundStyle(editorDisplayMode == mode ? WorkbenchTheme.primary : Color.secondary)
        .background(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .fill(editorDisplayMode == mode ? WorkbenchTheme.primary.opacity(WorkbenchOpacity.accentBackground) : Color.clear)
        )
        .accessibilityLabel("编辑器模式：\(mode.localizedDisplayName)")
        .accessibilityValue(editorDisplayMode == mode ? "已选择" : "未选择")
        .accessibilityAddTraits(editorDisplayMode == mode ? .isSelected : [])
        .help("切换到\(mode.localizedDisplayName)模式")
      }
    }
    .padding(2)
    .frame(width: 92, height: 28)
    .background(WorkbenchBackgroundStyle.badge, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
  }

  private func editorActionIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 13, weight: .medium))
      .frame(width: 24, height: 22)
      .contentShape(Rectangle())
  }

  private func aiActionGroupTitle(_ group: AIPublishingQuickPromptGroup) -> LocalizedStringKey {
    switch group {
    case .writing:
      return "写作生成"
    case .editing:
      return "选区编辑"
    case .publishing:
      return "发布检查"
    case .distribution:
      return "分发素材"
    case .maintenance:
      return "内容维护"
    }
  }

  private func articleAIActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    let availability = articleAIActionAvailability(item.kind)
    return Button {
      onPerformArticleAIAction(item.kind)
    } label: {
      Label(item.kind.localizedDisplayName, systemImage: item.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? item.kind.localizedDisplayName)
  }

  private func selectionAIActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    let availability = selectionAIActionAvailability(item.kind)
    return Button {
      onPerformSelectionAIAction(item.kind)
    } label: {
      Label(item.kind.localizedDisplayName, systemImage: item.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? item.kind.localizedDisplayName)
  }

  @ViewBuilder
  private func aiActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    if isSelectionAIAction(item.kind) {
      selectionAIActionButton(item)
    } else {
      articleAIActionButton(item)
    }
  }
}

struct MacMarkdownFormattingToolbar: View {
  let characterCount: Int
  let wordCount: Int
  let lineCount: Int
  let readingMinutes: Int
  let onApplyMarkdownFormatting: (MarkdownFormattingCommand) -> Void
  let onWrapSelection: (String, String, String) -> Void
  let onPrefixCurrentLine: (String) -> Void
  let onInsertCodeBlock: () -> Void
  let onInsertTable: () -> Void
  let onInsertHorizontalRule: () -> Void
  let onInsertImage: () -> Void

  var body: some View {
    HStack(spacing: 5) {
      Menu {
        Button("一级标题") { onApplyMarkdownFormatting(.heading(level: 1)) }
        Button("二级标题") { onApplyMarkdownFormatting(.heading(level: 2)) }
        Button("三级标题") { onApplyMarkdownFormatting(.heading(level: 3)) }
      } label: {
        toolbarIcon("textformat.size")
      }
      .help("标题级别")
      .accessibilityLabel("标题级别")

      Button {
        onApplyMarkdownFormatting(.bold)
      } label: {
        toolbarIcon("bold")
      }
      .help("粗体")
      .accessibilityLabel("粗体")

      Button {
        onApplyMarkdownFormatting(.italic)
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
        Button("引用") { onPrefixCurrentLine("> ") }
        Button("无序列表") { onPrefixCurrentLine("- ") }
        Button("有序列表") { onPrefixCurrentLine("1. ") }
        Button("任务列表") { onPrefixCurrentLine("- [ ] ") }
        Divider()
        Button("代码块") { onInsertCodeBlock() }
      } label: {
        toolbarIcon("list.bullet")
      }
      .help("段落与列表")
      .accessibilityLabel("段落与列表")

      Menu {
        Button("表格") { onInsertTable() }
        Button("分隔线") { onInsertHorizontalRule() }
        Divider()
        Button("链接") { onApplyMarkdownFormatting(.link) }
        Button("插图") { onInsertImage() }
      } label: {
        toolbarIcon("plus")
      }
      .help("插入内容")
      .accessibilityLabel("插入内容")

      Spacer()

      Text("\(characterCount) 字符 · 约 \(readingMinutes) min")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .help("\(characterCount) 字符 · \(wordCount) 词 · \(lineCount) 行 · 约 \(readingMinutes) 分钟")
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
