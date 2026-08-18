import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownFormattingToolbar: View {
  let characterCount: Int
  let hanCharacterCount: Int
  let wordCount: Int
  let writingUnitCount: Int
  let lineCount: Int
  let readingMinutes: Int
  let cursorPosition: MarkdownCursorPosition?
  let fenceMatch: MarkdownFenceMatch?
  let completion: MarkdownCompletionContext?
  let writingToolDensity: MarkdownWritingToolDensity
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
  let onJumpToLine: (Int) -> Void
  let onJumpToCounterpartFence: () -> Void
  let onApplyCompletion: (MarkdownCompletionCandidate) -> Void
  let onInsertCompletionTrigger: (MarkdownCompletionTrigger) -> Void
  var onFormatChineseTypography: (() -> Void)? = nil
  var onCopyForWeChatAndZhihu: (() -> Void)? = nil
  @AppStorage("workspace.customToolbarConfig") private var customToolbarConfigRawValue = ""
  @AppStorage("workspace.editorTargetWordCount") private var targetWordCount: Int = 0
  @State private var isStatsPopoverPresented = false

  private var toolbarConfiguration: MarkdownToolbarConfiguration {
    MarkdownToolbarConfiguration.decodeFromJSON(customToolbarConfigRawValue)
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
      .formatChineseTypography,
    ]
    return configuredFormattingItemIDs.filter(basicItems.contains)
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Group {
        if writingToolDensity == .basic {
          formattingRow(itemIDs: basicFormattingItemIDs, showsTitle: false)
        } else {
          formattingRow(itemIDs: configuredFormattingItemIDs, showsTitle: false)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 34)
    .buttonStyle(WorkbenchFocusRingButtonStyle())
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
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
      toolbarButton(title: "链接", systemName: "link", showsTitle: showsTitle) {
        onInsertInternalLink()
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
      toolbarButton(title: "中英文排版", systemName: "textformat", showsTitle: showsTitle) {
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
    ZenModeToggleButton(showsTitle: showsTitle)
    MarkdownEditorComfortControl(showsTitle: showsTitle)
    toolbarDivider
    MarkdownCursorWorkflowControls(
      position: cursorPosition,
      lineCount: lineCount,
      fenceMatch: fenceMatch,
      completion: completion,
      showsTitle: showsTitle,
      onJumpToLine: onJumpToLine,
      onJumpToCounterpartFence: onJumpToCounterpartFence,
      onApplyCompletion: onApplyCompletion,
      onInsertCompletionTrigger: onInsertCompletionTrigger
    )
    toolbarDivider
    statisticsLabel
  }

  private var toolbarDivider: some View {
    Divider()
      .frame(height: 18)
  }

  private var statisticsLabel: some View {
    Button {
      isStatsPopoverPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        if targetWordCount > 0 {
          let ratio = min(1.0, Double(writingUnitCount) / Double(targetWordCount))
          let percent = Int((Double(writingUnitCount) / Double(targetWordCount)) * 100)
          ProgressView(value: ratio)
            .progressViewStyle(.linear)
            .frame(width: 36)
            .tint(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.primary)
          Text("\(writingUnitCount)/\(targetWordCount) (\(percent)%)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(ratio >= 1.0 ? WorkbenchTheme.success : .primary)
        } else {
          Text(statisticsSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(isStatsPopoverPresented ? Color.secondary.opacity(0.12) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .help("点击查看详细统计与设定目标字数")
    .accessibilityLabel("文章统计与目标")
    .accessibilityValue(statisticsAccessibilityValue)
    .popover(isPresented: $isStatsPopoverPresented, arrowEdge: .bottom) {
      statisticsDetailPopover
    }
  }

  private var statisticsDetailPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("文章统计与目标", systemImage: "chart.bar.doc.horizontal")
          .font(.headline)
        Spacer()
        Text("⏱️ 约 \(readingMinutes) 分钟")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
        GridRow {
          statCard(title: "中文字数", value: "\(hanCharacterCount)")
          statCard(title: "西文单词", value: "\(wordCount)")
        }
        GridRow {
          statCard(title: "合计字词", value: "\(writingUnitCount)")
          statCard(title: "全部字符", value: "\(characterCount)")
        }
        GridRow {
          statCard(title: "正文行数", value: "\(lineCount)")
          statCard(title: "预估阅读", value: "\(readingMinutes) 分钟")
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Label("目标字数", systemImage: "target")
            .font(.subheadline.weight(.medium))
          Spacer()
          if targetWordCount > 0 {
            let ratio = Double(writingUnitCount) / Double(targetWordCount)
            let percent = Int(ratio * 100)
            Text("\(percent)%")
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.primary)
          }
        }

        if targetWordCount > 0 {
          let ratio = min(1.0, Double(writingUnitCount) / Double(targetWordCount))
          ProgressView(value: ratio)
            .progressViewStyle(.linear)
            .tint(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.primary)

          if writingUnitCount >= targetWordCount {
            Text("🎉 已达成目标字数！（超出 \(writingUnitCount - targetWordCount) 字）")
              .font(.caption)
              .foregroundStyle(WorkbenchTheme.success)
          } else {
            Text("还需 \(targetWordCount - writingUnitCount) 字达成目标")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 5) {
          ForEach([0, 500, 1000, 2000, 3000, 5000], id: \.self) { goal in
            Button {
              targetWordCount = goal
            } label: {
              Text(goal == 0 ? "无" : "\(goal)")
                .font(.workbenchMetadata)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  RoundedRectangle(cornerRadius: 4)
                    .fill(targetWordCount == goal ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .foregroundStyle(targetWordCount == goal ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
          }
        }
      }

      if onFormatChineseTypography != nil || onCopyForWeChatAndZhihu != nil {
        Divider()

        HStack(spacing: 8) {
          if let onFormatChineseTypography {
            Button {
              isStatsPopoverPresented = false
              onFormatChineseTypography()
            } label: {
              Label("排版优化", systemImage: "textformat")
                .font(.caption)
            }
          }

          if let onCopyForWeChatAndZhihu {
            Button {
              isStatsPopoverPresented = false
              onCopyForWeChatAndZhihu()
            } label: {
              Label("复制公众号", systemImage: "doc.on.doc")
                .font(.caption)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(width: 270)
  }

  private func statCard(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospacedDigit().weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statisticsSummary: String {
    String(
      localized: "⏱️ 约 \(readingMinutes) 分钟 · \(writingUnitCount) 字/词"
    )
  }

  private var statisticsAccessibilityValue: String {
    guard targetWordCount > 0 else { return statisticsSummary }
    let percent = Int((Double(writingUnitCount) / Double(targetWordCount)) * 100)
    return "\(statisticsSummary) · \(writingUnitCount)/\(targetWordCount) (\(percent)%)"
  }

  @ViewBuilder
  private func headingMenuButton(showsTitle: Bool) -> some View {
    Menu {
      ForEach(1...6, id: \.self) { level in
        Button {
          onApplyMarkdownFormatting(.heading(level: level))
        } label: {
          Label("\(level) 级标题 (H\(level))", systemImage: "textformat.size")
        }
      }
    } label: {
      if showsTitle {
        Label("标题", systemImage: "textformat.size")
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
      Button {
        onApplyAdvancedFormatting(.unorderedList)
      } label: {
        Label("无序列表", systemImage: "list.bullet")
      }
      Button {
        onApplyAdvancedFormatting(.orderedList)
      } label: {
        Label("有序列表", systemImage: "list.number")
      }
      Button {
        onApplyAdvancedFormatting(.taskList)
      } label: {
        Label("任务列表", systemImage: "checklist")
      }
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

private struct ZenModeToggleButton: View {
  @EnvironmentObject private var zenModeController: ZenModeController
  let showsTitle: Bool

  var body: some View {
    Button {
      zenModeController.toggleZenMode()
    } label: {
      if showsTitle {
        Label(
          zenModeController.isZenModeActive ? "退出沉浸" : "沉浸模式",
          systemImage: zenModeController.isZenModeActive ? "leaf.fill" : "leaf"
        )
      } else {
        Image(systemName: zenModeController.isZenModeActive ? "leaf.fill" : "leaf")
          .frame(width: 28, height: 28)
      }
    }
    .foregroundStyle(
      zenModeController.isZenModeActive ? WorkbenchTheme.navigationSelection : Color.secondary
    )
    .help(zenModeController.isZenModeActive ? "退出沉浸模式" : "开启沉浸模式（打字时自动淡出工具栏）")
    .accessibilityLabel("沉浸模式")
  }
}
