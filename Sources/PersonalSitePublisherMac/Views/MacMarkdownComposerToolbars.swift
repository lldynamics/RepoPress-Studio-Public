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
        onShowShortcutHelp()
      } label: {
        editorActionIcon("keyboard")
      }
      .help("快捷键说明")
      .accessibilityLabel("快捷键说明")

      Button {
        onOpenAIContextInspector()
      } label: {
        editorActionIcon("sparkles")
      }
      .help("打开 AI 对话")
      .accessibilityLabel("打开 AI 对话")

      Divider()
        .frame(height: 18)

      Menu {
        ForEach(writingAIActionMenuItems) { item in
          articleAIActionButton(item)
        }
      } label: {
        editorActionIcon("square.and.pencil")
      }
      .help("写作生成")
      .accessibilityLabel("写作生成")

      Menu {
        ForEach(publishingAIActionMenuItems) { item in
          articleAIActionButton(item)
        }
      } label: {
        editorActionIcon("checkmark.shield")
      }
      .help("发布检查")
      .accessibilityLabel("发布检查")

      Menu {
        ForEach(distributionAIActionMenuItems) { item in
          articleAIActionButton(item)
        }
      } label: {
        editorActionIcon("megaphone")
      }
      .help("分发素材")
      .accessibilityLabel("分发素材")

      Menu {
        ForEach(maintenanceAIActionMenuItems) { item in
          articleAIActionButton(item)
        }
      } label: {
        editorActionIcon("wrench.and.screwdriver")
      }
      .help("内容维护")
      .accessibilityLabel("内容维护")

      Menu {
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
      } label: {
        editorActionIcon("wand.and.stars")
      }
      .help("选区 AI 编辑")
      .accessibilityLabel("选区 AI 编辑")
      .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")

      Button {
        onPasteAIPromptToClipboard()
      } label: {
        editorActionIcon("doc.on.doc")
      }
      .help("复制上下文 Prompt")
      .accessibilityLabel("复制上下文 Prompt")
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
      Button {
        onApplyHeading(1)
      } label: {
        toolbarText("H1")
      }
      .help("一级标题")
      .accessibilityLabel("一级标题")

      Button {
        onApplyHeading(2)
      } label: {
        toolbarText("H2")
      }
      .help("二级标题")
      .accessibilityLabel("二级标题")

      Button {
        onApplyHeading(3)
      } label: {
        toolbarText("H3")
      }
      .help("三级标题")
      .accessibilityLabel("三级标题")

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

      Button {
        onPrefixCurrentLine("> ")
      } label: {
        toolbarIcon("quote.opening")
      }
      .help("引用")
      .accessibilityLabel("引用")

      Button {
        onPrefixCurrentLine("- ")
      } label: {
        toolbarIcon("list.bullet")
      }
      .help("无序列表")
      .accessibilityLabel("无序列表")

      Button {
        onPrefixCurrentLine("1. ")
      } label: {
        toolbarIcon("list.number")
      }
      .help("有序列表")
      .accessibilityLabel("有序列表")

      Button {
        onPrefixCurrentLine("- [ ] ")
      } label: {
        toolbarIcon("checklist")
      }
      .help("任务列表")
      .accessibilityLabel("任务列表")

      Button {
        onInsertCodeBlock()
      } label: {
        toolbarIcon("chevron.left.forwardslash.chevron.right")
      }
      .help("代码块")
      .accessibilityLabel("代码块")

      Button {
        onInsertTable()
      } label: {
        toolbarIcon("rectangle.grid.2x2")
      }
      .help("表格")
      .accessibilityLabel("表格")

      Button {
        onInsertHorizontalRule()
      } label: {
        toolbarIcon("minus")
      }
      .help("分隔线")
      .accessibilityLabel("分隔线")

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

  private func toolbarText(_ value: String) -> some View {
    Text(value)
      .font(.caption2.weight(.semibold))
      .frame(width: 22, height: 22)
  }
}
