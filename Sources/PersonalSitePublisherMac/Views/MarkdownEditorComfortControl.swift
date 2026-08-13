import SwiftUI

struct MarkdownEditorComfortControl: View {
  let showsTitle: Bool

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
  @AppStorage(MarkdownEditorComfortPreferences.warmPaperBackgroundEnabledKey)
  private var isWarmPaperBackgroundEnabled = MarkdownEditorComfortConfiguration.defaultWarmPaperBackgroundEnabled
  @AppStorage(MarkdownEditorComfortPreferences.automaticPairingEnabledKey)
  private var isAutomaticPairingEnabled = MarkdownEditorComfortConfiguration.defaultAutomaticPairingEnabled
  @AppStorage(MarkdownEditorComfortPreferences.typewriterSoundPresetKey)
  private var typewriterSoundPresetRawValue = TypewriterSoundPreset.typewriter.rawValue
  @AppStorage(MarkdownEditorComfortPreferences.paragraphSpotlightEnabledKey)
  private var isParagraphSpotlightEnabled = false
  @State private var isPresented = false

  init(showsTitle: Bool = false) {
    self.showsTitle = showsTitle
  }

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      if showsTitle {
        Label("编辑显示与辅助功能", systemImage: "textformat.size.smaller")
          .labelStyle(.titleAndIcon)
          .font(.workbenchButtonLabel)
          .fixedSize(horizontal: true, vertical: false)
          .padding(.horizontal, 6)
          .frame(minHeight: 28)
      } else {
        Image(systemName: "textformat.size.smaller")
          .frame(width: 28, height: 28)
      }
    }
    .foregroundStyle(.secondary)
    .help(String(localized: "编辑显示与辅助功能"))
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

      Toggle("柔和纸张背景", isOn: $isWarmPaperBackgroundEnabled)
        .toggleStyle(.switch)
        .help("为编辑器使用自适应的暖白或暖黑背景。")

      Toggle("自动补全括号、引号与代码标记", isOn: $isAutomaticPairingEnabled)
        .toggleStyle(.switch)
        .help("输入左侧符号时自动补全右侧符号；可随时撤销。")

      Toggle("段落焦点聚光灯（非焦点段落柔和淡出）", isOn: $isParagraphSpotlightEnabled)
        .toggleStyle(.switch)

      Picker("打字音效与微触觉", selection: $typewriterSoundPresetRawValue) {
        ForEach(TypewriterSoundPreset.allCases) { preset in
          Text(preset.title).tag(preset.rawValue)
        }
      }
      .pickerStyle(.menu)

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
    isWarmPaperBackgroundEnabled = MarkdownEditorComfortConfiguration.defaultWarmPaperBackgroundEnabled
    isAutomaticPairingEnabled = MarkdownEditorComfortConfiguration.defaultAutomaticPairingEnabled
  }
}
