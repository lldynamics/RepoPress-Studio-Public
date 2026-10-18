import PublishingDomainContracts
import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI

/// Save state and writing progress stay visible. Pointer hover reveals the
/// secondary cursor, branch, and diagnostic controls without removing their shortcuts.
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
  @State private var showsContextDetails = false

  var body: some View {
    GeometryReader { geometry in
      // Keep every workflow reachable even when a fence, completion, or long
      // localized status makes the row wider than the writing column.
      ScrollView(.horizontal) {
        HStack(spacing: WorkbenchSpacing.content) {
          MacMarkdownEditorSaveStatusIcon(
            store: store,
            draftID: draft.id,
            isCompact: false
          )
          .id(draft.id)
          .fixedSize(horizontal: true, vertical: false)

          Spacer(minLength: WorkbenchSpacing.content)

          HStack(spacing: WorkbenchSpacing.card) {
            contextDetails
              // Keep the controls mounted so ⌘L works before the first hover.
              .opacity(showsContextDetails ? 1 : 0)
              .frame(width: showsContextDetails ? nil : 0)
              .clipped()
              .allowsHitTesting(showsContextDetails)
              .accessibilityHidden(!showsContextDetails)

            MarkdownEditorStatisticsControl(
              draft: $draft,
              statisticsState: statisticsState,
              onFormatChineseTypography: onFormatChineseTypography,
              onCopyForWeChatAndZhihu: onCopyForWeChatAndZhihu
            )

          }
          .fixedSize(horizontal: true, vertical: false)
        }
        .frame(
          minWidth: max(0, geometry.size.width - WorkbenchSpacing.content * 2),
          minHeight: WorkbenchSpacing.page + WorkbenchSpacing.control
        )
        .padding(.horizontal, WorkbenchSpacing.content)
      }
    }
    .controlSize(.small)
    .frame(height: WorkbenchSpacing.page + WorkbenchSpacing.control)
    .background(.bar)
    .onHover { showsContextDetails = $0 }
    .onChange(of: draft.id) { _, _ in showsContextDetails = false }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("编辑器状态栏")
    .accessibilityIdentifier("markdown-editor-status-bar")
  }

  private var contextDetails: some View {
    HStack(spacing: WorkbenchSpacing.card) {
      if diagnosticCount > 0 { diagnosticsButton }
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
    }
  }

  /// Shown only when there is something to fix; a clean document stays quiet.
  private var diagnosticsButton: some View {
    Button(action: onShowDiagnostics) {
      Label(
        MarkdownEditorStatusBarPresentation.diagnosticsTitle(count: diagnosticCount),
        systemImage: "exclamationmark.triangle"
      )
      .font(.workbenchMetadata)
      .foregroundStyle(WorkbenchTheme.warning)
    }
    .buttonStyle(.plain)
    .help(String(localized: "查看正文诊断"))
    .accessibilityLabel("正文诊断")
    .accessibilityValue(String(localized: "\(diagnosticCount) 项"))
    .accessibilityIdentifier("markdown-editor-diagnostics")
  }
}

enum MarkdownEditorStatusBarPresentation {
  static func writingProgressSummary(writingUnitCount: Int, targetWordCount: Int) -> String {
    let count = max(0, writingUnitCount)
    guard targetWordCount > 0 else {
      return String(format: String(localized: "%lld 字/词"), locale: .current, Int64(count))
    }
    let percent = Int(Double(count) / Double(targetWordCount) * 100)
    return String(
      format: String(localized: "%lld / %lld 字/词 · %lld%%"), locale: .current,
      Int64(count), Int64(targetWordCount), Int64(percent)
    )
  }

  static func diagnosticsTitle(count: Int) -> String {
    String(
      format: String(localized: "%lld 项正文问题"), locale: .current, Int64(max(0, count))
    )
  }

  static func statisticsSummary(writingUnitCount: Int, readingMinutes: Int) -> String {
    String(
      format: String(localized: "%1$lld 字/词 · 约 %2$lld 分钟"),
      locale: .current,
      Int64(writingUnitCount),
      Int64(readingMinutes)
    )
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
      Label(statisticsSummary, systemImage: "timer")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .monospacedDigit()
        .padding(.horizontal, WorkbenchSpacing.tight)
        .padding(.vertical, 2)
        .background(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge)
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
          .font(.workbenchHeadline)
        Spacer()
        Label(readingTimeSummary, systemImage: "timer")
          .font(.workbenchMetadata.weight(.medium))
          .foregroundStyle(.workbenchSecondary)
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
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Label("目标字数", systemImage: "target")
            .font(.workbenchMetadata.weight(.medium))
          Spacer()
          if targetWordCount > 0 {
            let ratio = Double(writingUnitCount) / Double(targetWordCount)
            let percent = Int(ratio * 100)
            Text("\(percent)%")
              .font(.workbenchMetadata.monospacedDigit().weight(.semibold))
              .foregroundStyle(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.progress)
          }
        }

        if targetWordCount > 0 {
          let ratio = min(1.0, Double(writingUnitCount) / Double(targetWordCount))
          ProgressView(value: ratio)
            .progressViewStyle(.linear)
            .tint(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.progress)

          if writingUnitCount >= targetWordCount {
            Text("🎉 已达成目标字数！（超出 \(writingUnitCount - targetWordCount) 字）")
              .font(.workbenchMetadata)
              .foregroundStyle(WorkbenchTheme.success)
          } else {
            Text("还需 \(targetWordCount - writingUnitCount) 字达成目标")
              .font(.workbenchMetadata)
              .foregroundStyle(.workbenchSecondary)
          }
        }

        HStack(spacing: 5) {
          ForEach([0, 500, 1000, 2000, 3000, 5000], id: \.self) { goal in
            Button {
              setTargetWordCount(goal)
            } label: {
              Text(goal == 0 ? "无" : "\(goal)")
                .font(.workbenchMetadata)
                .padding(.horizontal, WorkbenchSpacing.icon)
                .padding(.vertical, WorkbenchSpacing.tight)
                .background(
                  RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge)
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
                .font(.workbenchMetadata)
            }
          }

          if let onCopyForWeChatAndZhihu {
            Button {
              isStatsPopoverPresented = false
              onCopyForWeChatAndZhihu()
            } label: {
              Label("复制公众号", systemImage: "doc.on.doc")
                .font(.workbenchMetadata)
            }
          }
        }
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(width: 270)
  }

  private func statCard(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
      Text(value)
        .font(.workbenchBody.monospacedDigit().weight(.semibold))
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
    MarkdownEditorStatusBarPresentation.writingProgressSummary(
      writingUnitCount: writingUnitCount, targetWordCount: targetWordCount
    )
  }

  private var readingTimeSummary: String {
    String(format: String(localized: "约 %lld 分钟"), locale: .current, Int64(readingMinutes))
  }

  private var statisticsAccessibilityValue: String {
    "\(statisticsSummary) · \(readingTimeSummary)"
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
      .font(.workbenchMetadata)
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
          .font(.workbenchHeadline)
        if let failure = saveStatus.saveFailure {
          Text(failure.message)
            .font(.workbenchBody)
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
          Text("发布进度请在右侧“发布检查”中查看。")
            .font(.workbenchBody)
            .foregroundStyle(.workbenchSecondary)
        }
        if let draft = store.draft(for: draftID), !draft.isGeneralDraft {
          Text(store.profile(for: draft).markdownPath(for: draft))
            .font(.workbenchMetadata.monospaced())
            .foregroundStyle(.workbenchSecondary)
            .textSelection(.enabled)
        }
      }
      .padding(WorkbenchSpacing.content)
      .frame(width: 340, alignment: .leading)
      .accessibilityIdentifier("markdown-editor-save-details")
    }
    .onChange(of: draftID) { _, updatedDraftID in
      isDetailPresented = false
      saveStatus.trackDraft(updatedDraftID)
    }
  }
}
