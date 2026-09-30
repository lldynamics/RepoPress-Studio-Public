import PublishingMarkdownCore
import SwiftUI

enum MarkdownFormattingToolbarPresentation {
  case standalone
  case integrated
}

struct MacMarkdownFormattingToolbar: View {
  let onApplyMarkdownFormatting: (MarkdownFormattingCommand) -> Void
  let onApplyAdvancedFormatting: (MarkdownAdvancedFormattingCommand) -> Void
  let onInsertCodeBlock: () -> Void
  let onInsertTable: () -> Void
  let onInsertHorizontalRule: () -> Void
  let onInsertInternalLink: () -> Void
  let onShowSnippets: () -> Void
  let onInsertImage: () -> Void
  let onInsertVideo: () -> Void
  var onFormatChineseTypography: (() -> Void)? = nil
  var presentation: MarkdownFormattingToolbarPresentation = .standalone
  var layout: MarkdownFormattingToolbarLayout = .automatic
  @EnvironmentObject private var zenModeController: ZenModeController

  var body: some View {
    toolbarContent
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 34)
      .buttonStyle(WorkbenchFocusRingButtonStyle())
      .padding(.horizontal, presentation == .integrated ? 0 : 10)
      .padding(.vertical, presentation == .integrated ? 0 : 6)
      .background {
        if presentation == .standalone {
          Rectangle().fill(.bar)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("格式工具栏")
      .accessibilityIdentifier("markdown-formatting-toolbar")
      .onKeyPress(.tab) {
        zenModeController.beginKeyboardNavigation()
        return .ignored
      }
      .onKeyPress(.leftArrow) {
        zenModeController.beginKeyboardNavigation()
        return .ignored
      }
      .onKeyPress(.rightArrow) {
        zenModeController.beginKeyboardNavigation()
        return .ignored
      }
      .onKeyPress(.upArrow) {
        zenModeController.beginKeyboardNavigation()
        return .ignored
      }
      .onKeyPress(.downArrow) {
        zenModeController.beginKeyboardNavigation()
        return .ignored
      }
      .onExitCommand {
        zenModeController.endKeyboardNavigation()
      }
      .onDisappear {
        zenModeController.endKeyboardNavigation()
      }
  }

  func withLayout(_ layout: MarkdownFormattingToolbarLayout) -> Self {
    var toolbar = self
    toolbar.layout = layout
    return toolbar
  }

  @ViewBuilder
  private var toolbarContent: some View {
    switch layout {
    case .automatic:
      ViewThatFits(in: .horizontal) {
        formattingRow(items: MarkdownToolbarLayout.primaryFormattingItems)
        scrollingFormattingRow
      }
    case .compact:
      formattingRow(items: MarkdownToolbarLayout.primaryFormattingItems)
    case .scrollable:
      scrollingFormattingRow
    }
  }

  private func formattingRow(items: [MarkdownToolbarFormattingItem]) -> some View {
    HStack(spacing: 5) {
      ForEach(items) { item in
        formattingItem(item, showsTitle: false)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 4)
  }

  private var scrollingFormattingRow: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(spacing: 5) {
        ForEach(MarkdownToolbarLayout.primaryFormattingItems) { item in
          formattingItem(item, showsTitle: false)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 4)
    }
  }

  @ViewBuilder
  private func formattingItem(
    _ item: MarkdownToolbarFormattingItem,
    showsTitle: Bool
  ) -> some View {
    switch item {
    case .headingMenu:
      headingMenuButton(showsTitle: showsTitle)
    case .bold:
      toolbarButton(title: "粗体", systemName: "bold", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.bold)
      }
    case .italic:
      toolbarButton(title: "斜体", systemName: "italic", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.italic)
      }
    case .listMenu:
      listMenuButton(showsTitle: showsTitle)
    case .link:
      toolbarButton(title: "Markdown 链接", systemName: "link", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.link)
      }
    case .image:
      toolbarButton(title: "插图", systemName: "photo", showsTitle: showsTitle) {
        onInsertImage()
      }
    case .insertMenu:
      groupedMenu(
        title: "插入",
        systemName: "plus.square",
        help: "插入代码块、表格、分隔线、视频、站内链接或组件",
        identifier: "markdown-insert-menu",
        items: MarkdownToolbarLayout.insertMenuItems
      )
    case .formatMenu:
      groupedMenu(
        title: "格式",
        systemName: "bold.italic.underline",
        help: "行内代码、引用、删除线与中英文排版",
        identifier: "markdown-format-menu",
        items: MarkdownToolbarLayout.formatMenuItems
      )
    default:
      secondaryFormattingItem(item, showsTitle: showsTitle)
    }
  }

  @ViewBuilder
  private func secondaryFormattingItem(
    _ item: MarkdownToolbarFormattingItem,
    showsTitle: Bool
  ) -> some View {
    switch item {
    case .inlineCode:
      toolbarButton(
        title: "行内代码", systemName: "chevron.left.forwardslash.chevron.right", showsTitle: showsTitle
      ) {
        onApplyAdvancedFormatting(.inlineCode)
      }
    case .blockquote:
      toolbarButton(title: "引用", systemName: "text.quote", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.blockquote)
      }
    case .codeBlock:
      toolbarButton(title: "代码块", systemName: "curlybraces.square", showsTitle: showsTitle) {
        onInsertCodeBlock()
      }
    case .strikethrough:
      toolbarButton(title: "删除线", systemName: "strikethrough", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.strikethrough)
      }
    case .table:
      toolbarButton(title: "表格", systemName: "tablecells", showsTitle: showsTitle) {
        onInsertTable()
      }
    case .horizontalRule:
      toolbarButton(title: "分隔线", systemName: "minus", showsTitle: showsTitle) {
        onInsertHorizontalRule()
      }
    case .internalLink:
      toolbarButton(title: "站内文章链接", systemName: "doc.on.doc", showsTitle: showsTitle) {
        onInsertInternalLink()
      }
    case .snippets:
      toolbarButton(title: "组件与片段", systemName: "rectangle.3.group", showsTitle: showsTitle) {
        onShowSnippets()
      }
    case .video:
      toolbarButton(title: "插入视频", systemName: "video", showsTitle: showsTitle) {
        onInsertVideo()
      }
    case .chineseTypography:
      toolbarButton(title: "中英文排版", systemName: "character.textbox", showsTitle: showsTitle) {
        onFormatChineseTypography?()
      }
    default:
      EmptyView()
    }
  }

  /// Icon-and-title menu so the two grouped entries read differently from
  /// the single-command icon buttons beside them.
  private func groupedMenu(
    title: LocalizedStringKey,
    systemName: String,
    help: LocalizedStringKey,
    identifier: String,
    items: [MarkdownToolbarFormattingItem]
  ) -> some View {
    Menu {
      ForEach(items) { item in
        secondaryFormattingItem(item, showsTitle: true)
      }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: systemName)
        Text(title)
          .font(.workbenchButtonLabel)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 5)
      .frame(minHeight: 28)
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(Text(title))
    .accessibilityIdentifier(identifier)
  }

  private func headingMenuButton(showsTitle: Bool) -> some View {
    Menu {
      MarkdownHeadingMenuItems { level in
        onApplyMarkdownFormatting(.heading(level: level))
      }
    } label: {
      if showsTitle {
        Label("标题", systemImage: "number")
      } else {
        HStack(spacing: 2) {
          Text("H")
            .font(.workbenchMetadata.weight(.semibold))
            .monospaced()
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 28, minHeight: 28)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("插入或切换标题 (H1-H6)")
    .accessibilityLabel("标题层级")
  }

  private func listMenuButton(showsTitle: Bool) -> some View {
    Menu {
      MarkdownListMenuItems(
        onSelectUnorderedList: { onApplyAdvancedFormatting(.unorderedList) },
        onSelectOrderedList: { onApplyAdvancedFormatting(.orderedList) },
        onSelectTaskList: { onApplyAdvancedFormatting(.taskList) }
      )
    } label: {
      if showsTitle {
        Label("列表", systemImage: "list.bullet")
      } else {
        HStack(spacing: 2) {
          Image(systemName: "list.bullet")
            .font(.system(size: 13, weight: .regular))
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 28, minHeight: 28)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("插入或切换列表（无序、有序、任务列表）")
    .accessibilityLabel("列表")
  }

  private func toolbarButton(
    title: LocalizedStringKey,
    systemName: String,
    showsTitle: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      toolbarLabel(title, systemName: systemName, showsTitle: showsTitle)
    }
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(Text(title))
  }

  @ViewBuilder
  private func toolbarLabel(
    _ title: LocalizedStringKey,
    systemName: String,
    showsTitle: Bool
  ) -> some View {
    if showsTitle {
      Label(title, systemImage: systemName)
        .labelStyle(.titleAndIcon)
        .font(.workbenchButtonLabel)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .frame(minHeight: 28)
    } else {
      Image(systemName: systemName)
        .frame(width: 28, height: 28)
    }
  }
}

/// Focus-mode switches shown inside the editor's “更多” menu; the View menu
/// command keeps the global shortcut.
struct MarkdownFocusModeToggles: View {
  @Binding var isActive: Bool
  @AppStorage(MarkdownEditorComfortPreferences.paragraphFocusEnabledKey)
  private var isParagraphFocusEnabled =
    MarkdownEditorComfortPreferences.initialParagraphFocusEnabled()

  var body: some View {
    Toggle(isOn: $isActive) {
      Label("专注模式", systemImage: "leaf")
    }
    .help("收起侧栏并在打字时淡出工具栏")
    .accessibilityIdentifier("markdown-focus-mode-toggle")
    Toggle(isOn: $isParagraphFocusEnabled) {
      Label("段落专注", systemImage: "text.aligncenter")
    }
    .help("让光标居中并高亮当前段落")
    .accessibilityIdentifier("markdown-paragraph-focus-toggle")
  }
}
