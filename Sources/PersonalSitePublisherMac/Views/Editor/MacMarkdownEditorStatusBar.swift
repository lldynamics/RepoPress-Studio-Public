import PublishingDomainContracts
import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI

/// Quiet status line under the writing surface. Cursor position, body
/// diagnostics, save state, and document statistics live here instead of in
/// the formatting toolbar so the toolbar holds only editing commands.
struct MacMarkdownEditorStatusBar: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  @ObservedObject var statisticsState: MarkdownComposerStatisticsState
  let diagnosticCount: Int
  let onShowDiagnostics: () -> Void
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

      if diagnosticCount > 0 {
        diagnosticsButton
      }

      Spacer(minLength: 8)

      MacMarkdownEditorSaveStatusIcon(
        store: store,
        draftID: draft.id,
        isCompact: false
      )
      .id(draft.id)

      MarkdownEditorStatisticsControl(
        draft: $draft,
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

  /// Shown only when there is something to fix; a clean document stays quiet.
  private var diagnosticsButton: some View {
    Button(action: onShowDiagnostics) {
      Label(
        String(localized: "\(min(diagnosticCount, 99)) 项正文问题"),
        systemImage: "exclamationmark.triangle"
      )
      .font(.caption)
      .foregroundStyle(WorkbenchTheme.warning)
    }
    .buttonStyle(.plain)
    .help(String(localized: "查看正文诊断"))
    .accessibilityLabel("正文诊断")
    .accessibilityValue(String(localized: "\(diagnosticCount) 项"))
    .accessibilityIdentifier("markdown-editor-diagnostics")
  }
}

private struct MarkdownEditorStatisticsControl: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Binding var draft: ArticleDraft
  @ObservedObject var statisticsState: MarkdownComposerStatisticsState
  let onFormatChineseTypography: (() -> Void)?
  let onCopyForWeChatAndZhihu: (() -> Void)?
  @State private var isStatsPopoverPresented = false
  @State private var customGoalText = ""

  private var targetWordCount: Int { draft.targetWordCount ?? 0 }
  private var customGoal: Int? {
    guard let value = Int(customGoalText.trimmingCharacters(in: .whitespacesAndNewlines)),
      (1...1_000_000).contains(value)
    else { return nil }
    return value
  }

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
      customGoalText = draft.targetWordCount.map(String.init) ?? ""
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
    .onChange(of: draft.id) { _, _ in
      customGoalText = draft.targetWordCount.map(String.init) ?? ""
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

      Text("字数按中文字数与西文单词合计。")
        .font(.caption)
        .foregroundStyle(.secondary)

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
              setTargetWordCount(goal)
            } label: {
              Text(goal == 0 ? "无" : "\(goal)")
                .font(.workbenchMetadata)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  RoundedRectangle(cornerRadius: 4)
                    .fill(
                      targetWordCount == goal
                        ? workbenchAccentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .foregroundStyle(targetWordCount == goal ? workbenchAccentColor : Color.primary)
            }
            .buttonStyle(.plain)
          }
        }

        HStack(spacing: 8) {
          TextField("自定义字数", text: $customGoalText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            .onSubmit(applyCustomGoal)
            .accessibilityLabel("自定义目标字数")
          Button("设定") {
            applyCustomGoal()
          }
          .disabled(customGoal == nil)
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
              Label("中英文排版", systemImage: "character.textbox")
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

  private func setTargetWordCount(_ count: Int) {
    draft.targetWordCount = count == 0 ? nil : count
    customGoalText = draft.targetWordCount.map(String.init) ?? ""
  }

  private func applyCustomGoal() {
    guard let customGoal else { return }
    setTargetWordCount(customGoal)
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

/// Fixed width keeps persistence transitions inside this leaf and avoids
/// repeatedly measuring the adaptive toolbar while the user is typing.
struct MacMarkdownEditorSaveStatusIcon: View {
  let store: WorkbenchStore
  let draftID: UUID
  let isCompact: Bool
  let accessibilityIdentifier: String
  @StateObject private var saveStatus: WorkbenchMarkdownEditorSaveStatusFeatureFacade
  @State private var isDetailPresented = false

  init(
    store: WorkbenchStore,
    draftID: UUID,
    isCompact: Bool,
    accessibilityIdentifier: String = "markdown-editor-save-status"
  ) {
    self.store = store
    self.draftID = draftID
    self.isCompact = isCompact
    self.accessibilityIdentifier = accessibilityIdentifier
    _saveStatus = StateObject(
      wrappedValue: WorkbenchMarkdownEditorSaveStatusFeatureFacade(store: store, draftID: draftID)
    )
  }

  private var statusImage: String {
    if saveStatus.saveFailure != nil { return "exclamationmark.triangle.fill" }
    return saveStatus.hasUnsavedChanges ? "clock" : "checkmark.circle.fill"
  }

  var body: some View {
    Button {
      isDetailPresented.toggle()
    } label: {
      Group {
        if isCompact {
          Image(systemName: statusImage)
            .frame(width: 28, height: 28)
        } else {
          Label(saveStatus.shortSaveStatus, systemImage: statusImage)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .font(.caption)
      .foregroundStyle(
        saveStatus.saveFailure != nil
          ? WorkbenchTheme.warning
          : (saveStatus.hasUnsavedChanges ? Color.secondary : WorkbenchTheme.success)
      )
    }
    .buttonStyle(.borderless)
    .frame(width: isCompact ? 30 : nil, height: isCompact ? 30 : nil)
    .help(saveStatus.lastSaveStatus)
    .accessibilityLabel("保存状态")
    .accessibilityValue(saveStatus.shortSaveStatus)
    .accessibilityIdentifier(accessibilityIdentifier)
    .popover(isPresented: $isDetailPresented) {
      VStack(alignment: .leading, spacing: 10) {
        Label(saveStatus.shortSaveStatus, systemImage: statusImage)
          .font(.headline)
        if let failure = saveStatus.saveFailure {
          Text(failure.message)
            .font(.callout)
            .textSelection(.enabled)
          if failure.scope == .project {
            Button(
              saveStatus.hasProjectFileConflict
                ? String(localized: "处理冲突…") : String(localized: "处理项目保存问题…")
            ) {
              isDetailPresented = false
              if saveStatus.hasProjectFileConflict {
                ProjectFileConflictReviewPanel.present(for: store, draftID: draftID)
              } else {
                ProjectFileSaveRecoveryPanel.present(for: store)
              }
            }
          } else if failure.canRetry {
            Button("重新保存") { saveStatus.retrySave() }
          }
        } else {
          Text("发布进度请在“准备发布”中查看。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let draft = store.draft(for: draftID), !draft.isGeneralDraft {
          Text(store.profile(for: draft).markdownPath(for: draft))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(16)
      .frame(width: 340, alignment: .leading)
      .accessibilityIdentifier("markdown-editor-save-details")
    }
    .onChange(of: draftID) { _, updatedDraftID in
      isDetailPresented = false
      saveStatus.trackDraft(updatedDraftID)
    }
  }
}
