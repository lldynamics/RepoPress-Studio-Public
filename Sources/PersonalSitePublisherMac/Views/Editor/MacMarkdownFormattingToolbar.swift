import PublishingMarkdownCore
import SwiftUI

enum MarkdownFormattingToolbarPresentation {
  case standalone
  case integrated
}

struct MacMarkdownFormattingToolbar: View {
  let writingToolDensity: MarkdownWritingToolDensity
  @Binding var isFocusModeActive: Bool
  let onApplyMarkdownFormatting: (MarkdownFormattingCommand) -> Void
  let onApplyAdvancedFormatting: (MarkdownAdvancedFormattingCommand) -> Void
  let onEditLines: (MarkdownLineEditingCommand) -> Void
  let onWrapSelection: (String, String, String) -> Void
  let onPrefixCurrentLine: (String) -> Void
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
  @AppStorage("workspace.customToolbarConfig") private var customToolbarConfigRawValue = ""
  @State private var isCustomizationSheetPresented = false
  @EnvironmentObject private var zenModeController: ZenModeController

  private var toolbarConfiguration: MarkdownToolbarConfiguration {
    MarkdownToolbarConfiguration.decodeFromJSON(customToolbarConfigRawValue)
  }

  private var toolbarConfigurationBinding: Binding<MarkdownToolbarConfiguration> {
    Binding(
      get: { toolbarConfiguration },
      set: { customToolbarConfigRawValue = $0.normalized.encodeToJSON() }
    )
  }

  private var configuredFormattingItemIDs: [MarkdownToolbarItemID] {
    toolbarConfiguration.formattingItemIDs
  }

  private var basicFormattingItemIDs: [MarkdownToolbarItemID] {
    let basicItems: Set<MarkdownToolbarItemID> = [
      .headingMenu,
      .heading1,
      .heading2,
      .bold,
      .italic,
      .listMenu,
      .unorderedList,
      .link,
      .image,
      .moreInsertions,
      .formatChineseTypography,
    ]
    var items = configuredFormattingItemIDs.filter(basicItems.contains)
    if !items.contains(.moreInsertions) {
      items.append(.moreInsertions)
    }
    return items
  }

  var body: some View {
    HStack(spacing: 4) {
      ScrollView(.horizontal, showsIndicators: true) {
        Group {
          if writingToolDensity == .basic {
            formattingRow(itemIDs: basicFormattingItemIDs, showsTitle: false)
          } else {
            formattingRow(itemIDs: configuredFormattingItemIDs, showsTitle: false)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
      }

      formattingToolbarOptions
    }
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
    .sheet(isPresented: $isCustomizationSheetPresented) {
      MacMarkdownToolbarCustomizationView(
        configuration: toolbarConfigurationBinding,
        onDismiss: { isCustomizationSheetPresented = false }
      )
    }
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

  private func formattingRow(
    itemIDs: [MarkdownToolbarItemID],
    showsTitle: Bool
  ) -> some View {
    HStack(spacing: 5) {
      ForEach(itemIDs) { item in
        formattingItem(item, showsTitle: showsTitle)
      }
      Spacer(minLength: 8)
      fixedTrailingControls(showsTitle: showsTitle)
    }
  }

  private var formattingToolbarOptions: some View {
    Menu {
      Section("全部格式") {
        ForEach(configuredFormattingItemIDs) { item in
          formattingItem(item, showsTitle: true)
        }
      }
      Divider()
      fixedTrailingControls(showsTitle: true)
      Divider()
      Button {
        isCustomizationSheetPresented = true
      } label: {
        Label("自定义工具栏…", systemImage: "slider.horizontal.3")
      }
    } label: {
      Label("格式与自定义", systemImage: "ellipsis.circle")
        .font(.workbenchButtonLabel)
        .frame(minHeight: 30)
    }
    .menuIndicator(.hidden)
    .buttonStyle(WorkbenchFocusRingButtonStyle())
    .help("打开全部格式与自定义工具栏")
    .accessibilityLabel("格式与自定义工具栏")
    .accessibilityIdentifier("markdown-formatting-options")
  }

  @ViewBuilder
  private func formattingItem(
    _ item: MarkdownToolbarItemID,
    showsTitle: Bool
  ) -> some View {
    switch item {
    case .headingMenu:
      headingMenuButton(showsTitle: showsTitle)
    case .listMenu:
      listMenuButton(showsTitle: showsTitle)
    case .heading1:
      headingButton(level: 1, title: "一级标题", showsTitle: showsTitle)
    case .heading2:
      headingButton(level: 2, title: "二级标题", showsTitle: showsTitle)
    case .heading3:
      headingButton(level: 3, title: "三级标题", showsTitle: showsTitle)
    case .bold:
      toolbarButton(title: "粗体", systemName: "bold", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.bold)
      }
    case .italic:
      toolbarButton(title: "斜体", systemName: "italic", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.italic)
      }
    case .inlineCode:
      toolbarButton(
        title: "行内代码",
        systemName: "chevron.left.forwardslash.chevron.right",
        showsTitle: showsTitle
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
    case .unorderedList:
      toolbarButton(title: "无序列表", systemName: "list.bullet", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.unorderedList)
      }
    case .orderedList:
      toolbarButton(title: "有序列表", systemName: "list.number", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.orderedList)
      }
    case .taskList:
      toolbarButton(title: "任务列表", systemName: "checklist", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.taskList)
      }
    case .link:
      toolbarButton(title: "Markdown 链接", systemName: "link", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.link)
      }
    case .image:
      toolbarButton(title: "插图", systemName: "photo", showsTitle: showsTitle) {
        onInsertImage()
      }
    case .moreInsertions:
      moreInsertionsMenu(showsTitle: showsTitle)
    case .diagnostics:
      diagnosticButton(showsTitle: showsTitle)
    case .formatChineseTypography:
      toolbarButton(title: "中英文排版", systemName: "character.textbox", showsTitle: showsTitle) {
        onFormatChineseTypography?()
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func moreInsertionsMenu(showsTitle: Bool) -> some View {
    Menu {
      Button {
        onApplyAdvancedFormatting(.strikethrough)
      } label: {
        Label("删除线", systemImage: "strikethrough")
      }

      Divider()

      Button {
        onInsertTable()
      } label: {
        Label("表格", systemImage: "tablecells")
      }
      Button {
        onInsertHorizontalRule()
      } label: {
        Label("分隔线", systemImage: "minus")
      }
      Button {
        onInsertInternalLink()
      } label: {
        Label("站内文章链接", systemImage: "doc.on.doc")
      }
      Button {
        onShowSnippets()
      } label: {
        Label("组件与片段", systemImage: "rectangle.3.group")
      }
      Button {
        onInsertVideo()
      } label: {
        Label("插入视频", systemImage: "video")
      }
    } label: {
      toolbarLabel("更多插入选项", systemName: "ellipsis.circle", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("更多插入选项")
    .accessibilityLabel("更多插入选项")
  }

  @ViewBuilder
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

  @ViewBuilder
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

  @ViewBuilder
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

  private func headingButton(
    level: Int,
    title: LocalizedStringKey,
    showsTitle: Bool
  ) -> some View {
    Button {
      onApplyMarkdownFormatting(.heading(level: level))
    } label: {
      if showsTitle {
        Label {
          Text(title)
        } icon: {
          Text("H\(level)")
            .font(.workbenchMetadata.weight(.semibold))
            .monospaced()
        }
      } else {
        Text("H\(level)")
          .font(.workbenchMetadata.weight(.semibold))
          .monospaced()
          .frame(width: 28, height: 28)
      }
    }
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(Text(title))
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
  @AppStorage(MarkdownEditorComfortPreferences.focusToolbarFadeEnabledKey)
  private var isFocusToolbarFadeEnabled = true
  @AppStorage(MarkdownEditorComfortPreferences.typewriterModeEnabledKey)
  private var isTypewriterModeEnabled = MarkdownEditorComfortConfiguration
    .defaultTypewriterModeEnabled
  @AppStorage(MarkdownEditorComfortPreferences.paragraphSpotlightEnabledKey)
  private var isParagraphSpotlightEnabled = MarkdownEditorComfortConfiguration
    .defaultParagraphSpotlightEnabled
  let showsTitle: Bool

  var body: some View {
    Menu {
      Toggle("专注模式", isOn: $isActive)
      Divider()
      Toggle("打字时淡出工具栏", isOn: $isFocusToolbarFadeEnabled)
      Toggle("打字机模式", isOn: $isTypewriterModeEnabled)
      Toggle("段落聚光灯", isOn: $isParagraphSpotlightEnabled)
    } label: {
      if showsTitle {
        Label(
          "专注模式",
          systemImage: isActive ? "leaf.fill" : "leaf"
        )
      } else {
        Image(systemName: isActive ? "leaf.fill" : "leaf")
          .frame(width: 28, height: 28)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(isActive ? workbenchAccentColor : Color.secondary)
    .help("专注模式与选项（⇧⌘F）")
    .accessibilityLabel("专注模式与选项")
    .accessibilityValue(isActive ? "已开启" : "未开启")
    .accessibilityIdentifier("markdown-focus-mode-menu")
  }
}
