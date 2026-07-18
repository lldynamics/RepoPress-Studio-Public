import SwiftUI

struct MarkdownEditorComfortControl: View {
  @AppStorage(MarkdownEditorComfortPreferences.fontSizeKey)
  private var fontSize = MarkdownEditorComfortConfiguration.defaultFontSize
  @AppStorage(MarkdownEditorComfortPreferences.lineSpacingKey)
  private var lineSpacing = MarkdownEditorComfortConfiguration.defaultLineSpacing
  @AppStorage(MarkdownEditorComfortPreferences.bodyWidthKey)
  private var bodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
  @AppStorage(MarkdownEditorComfortPreferences.spellCheckEnabledKey)
  private var isSpellCheckEnabled = MarkdownEditorComfortConfiguration.defaultSpellCheckEnabled
  @AppStorage(MarkdownEditorComfortPreferences.typewriterModeEnabledKey)
  private var isTypewriterModeEnabled = MarkdownEditorComfortConfiguration.defaultTypewriterModeEnabled
  @AppStorage(MarkdownEditorComfortPreferences.currentParagraphHighlightEnabledKey)
  private var isCurrentParagraphHighlightEnabled = MarkdownEditorComfortConfiguration.defaultCurrentParagraphHighlightEnabled
  @AppStorage(MarkdownEditorComfortPreferences.writingGoalKey)
  private var writingGoal = MarkdownEditorComfortConfiguration.defaultWritingGoal
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Image(systemName: "textformat.size.smaller")
        .frame(width: 22, height: 22)
    }
    .help("编辑显示与辅助功能")
    .accessibilityLabel("编辑显示与辅助功能")
    .accessibilityValue(accessibilitySummary)
    .popover(isPresented: $isPresented, arrowEdge: .top) {
      controls
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("编辑显示与辅助功能", systemImage: "textformat.size")
        .font(.headline)

      preferenceSlider(
        title: "字号",
        value: $fontSize,
        range: MarkdownEditorComfortConfiguration.fontSizeRange,
        step: 1,
        formattedValue: "\(Int(fontSize)) pt"
      )

      preferenceSlider(
        title: "行距",
        value: $lineSpacing,
        range: MarkdownEditorComfortConfiguration.lineSpacingRange,
        step: 1,
        formattedValue: "\(Int(lineSpacing)) pt"
      )

      preferenceSlider(
        title: "正文宽度",
        value: $bodyWidth,
        range: MarkdownEditorComfortConfiguration.bodyWidthRange,
        step: 20,
        formattedValue: "\(Int(bodyWidth)) pt"
      )

      Toggle("拼写检查", isOn: $isSpellCheckEnabled)
        .toggleStyle(.switch)

      Toggle("打字机模式（光标保持居中）", isOn: $isTypewriterModeEnabled)
        .toggleStyle(.switch)

      Toggle("高亮当前段落", isOn: $isCurrentParagraphHighlightEnabled)
        .toggleStyle(.switch)

      Stepper(value: $writingGoal, in: 100...20_000, step: 100) {
        HStack {
          Text("写作目标")
          Spacer()
          Text("\(writingGoal) 字/词")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .help("中文按汉字计数，其他语言按词计数。")

      Divider()

      HStack {
        Text("设置会自动保存并应用到所有文章。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("恢复默认") {
          resetDefaults()
        }
      }
    }
    .padding(16)
    .frame(width: 340)
  }

  private func preferenceSlider(
    title: LocalizedStringKey,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    formattedValue: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text(formattedValue)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: value, in: range, step: step)
        .accessibilityLabel(Text(title))
        .accessibilityValue(formattedValue)
    }
  }

  private var accessibilitySummary: String {
    let spellCheckState = isSpellCheckEnabled
      ? String(localized: "开启")
      : String(localized: "未开启")
    return String(
      format: String(localized: "字号 %@，行距 %@，正文宽度 %@，拼写检查%@"),
      "\(Int(fontSize))",
      "\(Int(lineSpacing))",
      "\(Int(bodyWidth))",
      spellCheckState
    )
  }

  private func resetDefaults() {
    fontSize = MarkdownEditorComfortConfiguration.defaultFontSize
    lineSpacing = MarkdownEditorComfortConfiguration.defaultLineSpacing
    bodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
    isSpellCheckEnabled = MarkdownEditorComfortConfiguration.defaultSpellCheckEnabled
    isTypewriterModeEnabled = MarkdownEditorComfortConfiguration.defaultTypewriterModeEnabled
    isCurrentParagraphHighlightEnabled = MarkdownEditorComfortConfiguration.defaultCurrentParagraphHighlightEnabled
    writingGoal = MarkdownEditorComfortConfiguration.defaultWritingGoal
  }
}
