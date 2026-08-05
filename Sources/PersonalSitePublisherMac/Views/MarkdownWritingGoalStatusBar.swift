import SwiftUI

struct MarkdownWritingGoalProgress: Equatable, Sendable {
  let currentCount: Int
  let goal: Int

  var normalizedCurrentCount: Int {
    max(0, currentCount)
  }

  var fraction: Double {
    guard goal > 0 else { return 0 }
    return min(1, Double(normalizedCurrentCount) / Double(goal))
  }

  var percentage: Int {
    Int(fraction * 100)
  }

  var isComplete: Bool {
    goal > 0 && normalizedCurrentCount >= goal
  }
}

struct MacMarkdownWritingGoalStatusBar: View {
  let currentCount: Int
  @Binding var writingGoal: Int
  @State private var isGoalEditorPresented = false

  private var progress: MarkdownWritingGoalProgress {
    MarkdownWritingGoalProgress(currentCount: currentCount, goal: effectiveGoal)
  }

  private var effectiveGoal: Int {
    min(max(writingGoal, 100), 20_000)
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      expandedContent
      compactContent
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
    .onAppear(perform: normalizeWritingGoal)
    .onChange(of: writingGoal) { _, _ in
      normalizeWritingGoal()
    }
  }

  private var expandedContent: some View {
    HStack(spacing: 9) {
      progressLabel

      ProgressView(value: progress.fraction)
        .progressViewStyle(.linear)
        .tint(.accentColor)
        .frame(minWidth: 110, idealWidth: 220, maxWidth: 320)
        .accessibilityLabel("写作进度")
        .accessibilityValue(progressAccessibilityValue)
        .accessibilityIdentifier("markdown-writing-goal-progress")

      Text(progressSummary)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)

      Spacer(minLength: 4)
      goalEditorButton(showsTitle: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var compactContent: some View {
    HStack(spacing: 8) {
      progressLabel

      ProgressView(value: progress.fraction)
        .progressViewStyle(.linear)
        .tint(.accentColor)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("写作进度")
        .accessibilityValue(progressAccessibilityValue)
        .accessibilityIdentifier("markdown-writing-goal-progress")

      Text("\(progress.normalizedCurrentCount) / \(effectiveGoal)")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)

      goalEditorButton(showsTitle: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var progressLabel: some View {
    Label(
      progress.isComplete ? "目标已达成" : "目标字数",
      systemImage: progress.isComplete ? "checkmark.circle.fill" : "target"
    )
    .font(.caption.weight(.medium))
    .foregroundStyle(progress.isComplete ? Color.accentColor : Color.secondary)
    .fixedSize(horizontal: true, vertical: false)
  }

  private func goalEditorButton(showsTitle: Bool) -> some View {
    Button {
      isGoalEditorPresented = true
    } label: {
      if showsTitle {
        Label("调整目标", systemImage: "pencil")
      } else {
        Image(systemName: "pencil")
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help("调整写作目标")
    .accessibilityLabel("调整写作目标")
    .accessibilityValue("当前目标 \(effectiveGoal) 字/词")
    .accessibilityIdentifier("markdown-writing-goal-editor")
    .popover(isPresented: $isGoalEditorPresented, arrowEdge: .bottom) {
      goalEditor
    }
  }

  private var goalEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("写作目标", systemImage: "target")
        .font(.headline)

      Stepper(value: $writingGoal, in: 100...20_000, step: 100) {
        HStack {
          Text("目标字数")
          Spacer()
          Text("\(effectiveGoal) 字/词")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }

      Text("中文按汉字计数，其他语言按词计数。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 280)
  }

  private var progressSummary: String {
    "\(progress.normalizedCurrentCount) / \(effectiveGoal) 字/词（\(progress.percentage)%）"
  }

  private var progressAccessibilityValue: String {
    "\(progress.normalizedCurrentCount) 个字词，共 \(effectiveGoal) 个目标字词，完成 \(progress.percentage)%"
  }

  private func normalizeWritingGoal() {
    let normalizedGoal = effectiveGoal
    guard writingGoal != normalizedGoal else { return }
    writingGoal = normalizedGoal
  }
}
