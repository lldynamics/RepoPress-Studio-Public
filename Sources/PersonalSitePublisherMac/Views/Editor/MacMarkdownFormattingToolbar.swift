import PublishingMarkdownCore
import SwiftUI

enum MarkdownFormattingToolbarPresentation {
  case standalone
  case integrated
}

struct MacMarkdownFormattingToolbar: View {
  @Binding var isFocusModeActive: Bool
  let onApplyMarkdownFormatting: (MarkdownFormattingCommand) -> Void
  let onApplyAdvancedFormatting: (MarkdownAdvancedFormattingCommand) -> Void
  let onInsertCodeBlock: () -> Void
  let onInsertTable: () -> Void
  let onInsertHorizontalRule: () -> Void
  let onInsertInternalLink: () -> Void
  let onShowSnippets: () -> Void
  let onShowDiagnostics: () -> Void
  let diagnosticCount: Int
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
        formattingRow(items: MarkdownToolbarLayout.expandedFormattingItems)
        formattingRow(items: MarkdownToolbarLayout.primaryFormattingItems)
        scrollingFormattingRow
      }
    case .expanded:
      formattingRow(items: MarkdownToolbarLayout.expandedFormattingItems)
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
      Divider().frame(height: 18)
      fixedTrailingControls(showsTitle: false)
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 4)
  }

  private var scrollingFormattingRow: some View {
    HStack(spacing: 5) {
      ScrollView(.horizontal, showsIndicators: true) {
        HStack(spacing: 5) {
          ForEach(MarkdownToolbarLayout.primaryFormattingItems) { item in
            formattingItem(item, showsTitle: false)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
      }
      Divider().frame(height: 18)
      fixedTrailingControls(showsTitle: false)
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
    case .moreFormatting:
      moreFormattingMenu(showsTitle: showsTitle)
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
    case .diagnostics:
      diagnosticButton(showsTitle: showsTitle)
    default:
      EmptyView()
    }
  }

  private func moreFormattingMenu(showsTitle: Bool) -> some View {
    Menu {
      ForEach(MarkdownToolbarLayout.moreFormattingItems) { item in
        secondaryFormattingItem(item, showsTitle: true)
      }
    } label: {
      toolbarLabel("更多格式", systemName: "ellipsis.circle", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("更多格式")
    .accessibilityLabel("更多格式")
    .accessibilityIdentifier("markdown-more-formatting-menu")
  }

  private func diagnosticButton(showsTitle: Bool) -> some View {
    Button {
      onShowDiagnostics()
    } label: {
      ZStack(alignment: .topTrailing) {
        toolbarLabel(
          "正文诊断",
          systemName: diagnosticCount == 0 ? "checkmark.circle" : "waveform.badge.exclamationmark",
          showsTitle: showsTitle
        )
        if diagnosticCount > 0 {
          Text("\(min(diagnosticCount, 99))")
            .font(.workbenchMetadata.weight(.bold))
            .padding(.horizontal, 3)
            .background(WorkbenchTheme.warningActionFill, in: Capsule())
            .foregroundStyle(.white)
            .offset(x: 4, y: -3)
        }
      }
    }
    .foregroundStyle(diagnosticCount == 0 ? Color.secondary : WorkbenchTheme.warning)
    .help(
      diagnosticCount == 0
        ? String(localized: "正文诊断：未发现问题")
        : String(localized: "正文诊断：\(diagnosticCount) 项")
    )
    .accessibilityLabel("正文诊断")
    .accessibilityValue(
      diagnosticCount == 0
        ? String(localized: "没有问题")
        : String(localized: "\(diagnosticCount) 项")
    )
  }

  @ViewBuilder
  private func fixedTrailingControls(showsTitle: Bool) -> some View {
    FocusModeMenu(isActive: $isFocusModeActive, showsTitle: showsTitle)
    MarkdownEditorComfortControl(showsTitle: showsTitle)
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

private struct FocusModeMenu: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Binding var isActive: Bool
  @AppStorage(MarkdownEditorComfortPreferences.paragraphFocusEnabledKey)
  private var isParagraphFocusEnabled =
    MarkdownEditorComfortPreferences.initialParagraphFocusEnabled()
  let showsTitle: Bool

  private var isAnyModeActive: Bool { isActive || isParagraphFocusEnabled }

  private var accessibilitySummary: String {
    String(
      format: String(localized: "专注模式：%@；段落专注：%@"),
      isActive ? String(localized: "已开启") : String(localized: "未开启"),
      isParagraphFocusEnabled ? String(localized: "已开启") : String(localized: "未开启")
    )
  }

  var body: some View {
    Menu {
      Toggle("专注模式", isOn: $isActive)
      Toggle("段落专注", isOn: $isParagraphFocusEnabled)
    } label: {
      if showsTitle {
        Label("专注模式", systemImage: isAnyModeActive ? "leaf.fill" : "leaf")
      } else {
        Image(systemName: isAnyModeActive ? "leaf.fill" : "leaf")
          .frame(width: 28, height: 28)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(isAnyModeActive ? workbenchAccentColor : Color.secondary)
    .help("专注模式会收起侧栏并在打字时淡出工具栏；段落专注会让光标居中并高亮当前段落。")
    .accessibilityLabel("专注模式与段落专注")
    .accessibilityValue(accessibilitySummary)
    .accessibilityIdentifier("markdown-focus-mode-menu")
  }
}
