import PublishingDomainContracts
import PublishingMarkdownCore
import SwiftUI

/// Quiet status line under the writing surface. Cursor position and document
/// statistics live here instead of in the formatting toolbar so the toolbar
/// holds only editing commands and the text starts closer to the title.
struct MacMarkdownEditorStatusBar: View {
  @ObservedObject var statisticsState: MarkdownComposerStatisticsState
  let cursorPosition: MarkdownCursorPosition?
  let fenceMatch: MarkdownFenceMatch?
  let completion: MarkdownCompletionContext?
  let onJumpToLine: (Int) -> Void
  let onJumpToCounterpartFence: () -> Void
  let onApplyCompletion: (MarkdownCompletionCandidate) -> Void
  let onInsertCompletionTrigger: (MarkdownCompletionTrigger) -> Void
  var onFormatChineseTypography: (() -> Void)? = nil
  var onCopyForWeChatAndZhihu: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 8) {
      MarkdownCursorWorkflowControls(
        position: cursorPosition,
        lineCount: statisticsState.value.lineCount,
        fenceMatch: fenceMatch,
        completion: completion,
        showsTitle: false,
        onJumpToLine: onJumpToLine,
        onJumpToCounterpartFence: onJumpToCounterpartFence,
        onApplyCompletion: onApplyCompletion,
        onInsertCompletionTrigger: onInsertCompletionTrigger
      )

      Spacer(minLength: 8)

      MarkdownEditorStatisticsControl(
        statisticsState: statisticsState,
        onFormatChineseTypography: onFormatChineseTypography,
        onCopyForWeChatAndZhihu: onCopyForWeChatAndZhihu
      )
    }
    .controlSize(.small)
    .padding(.horizontal, 12)
    .frame(height: 26)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("编辑器状态栏")
    .accessibilityIdentifier("markdown-editor-status-bar")
  }
}

private struct MarkdownEditorStatisticsControl: View {
  @ObservedObject var statisticsState: MarkdownComposerStatisticsState
  let onFormatChineseTypography: (() -> Void)?
  let onCopyForWeChatAndZhihu: (() -> Void)?
  @AppStorage("workspace.editorTargetWordCount") private var targetWordCount: Int = 0
  @State private var isStatsPopoverPresented = false

  private var characterCount: Int { statisticsState.value.characterCount }
  private var hanCharacterCount: Int { statisticsState.value.hanCharacterCount }
  private var wordCount: Int { statisticsState.value.wordCount }
  private var writingUnitCount: Int { statisticsState.value.writingUnitCount }
  private var lineCount: Int { statisticsState.value.lineCount }
  private var readingMinutes: Int { statisticsState.value.readingMinutes }

  var body: some View {
    statisticsLabel
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
          Label(statisticsSummary, systemImage: "timer")
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
    .popover(isPresented: $isStatsPopoverPresented, arrowEdge: .top) {
      statisticsDetailPopover
    }
  }

  private var statisticsDetailPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("文章统计与目标", systemImage: "chart.bar.doc.horizontal")
          .font(.headline)
        Spacer()
        Label(readingTimeSummary, systemImage: "timer")
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
                    .fill(
                      targetWordCount == goal
                        ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
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
              Label("排版优化", systemImage: "character.textbox")
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

  // Explicit %lld templates keep the catalog key identical to the runtime
  // key; interpolating an Int extracted as %@ and never matched in English.
  private var statisticsSummary: String {
    String(
      format: String(localized: "约 %lld 分钟 · %lld 字/词"),
      locale: .current,
      Int64(readingMinutes),
      Int64(writingUnitCount)
    )
  }

  private var readingTimeSummary: String {
    String(format: String(localized: "约 %lld 分钟"), locale: .current, Int64(readingMinutes))
  }

  private var statisticsAccessibilityValue: String {
    guard targetWordCount > 0 else { return statisticsSummary }
    let percent = Int((Double(writingUnitCount) / Double(targetWordCount)) * 100)
    return "\(statisticsSummary) · \(writingUnitCount)/\(targetWordCount) (\(percent)%)"
  }
}
