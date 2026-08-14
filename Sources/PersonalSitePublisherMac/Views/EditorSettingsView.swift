import SwiftUI

/// Application-wide editor preferences.
///
/// These controls intentionally bind to the same `@AppStorage` keys used by
/// the composer and its preview. The settings page is only another
/// presentation of those persisted values; it does not introduce a second
/// editor configuration source.
struct EditorSettingsView: View {
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
  @AppStorage(MarkdownEditorComfortPreferences.paragraphSpotlightEnabledKey)
  private var isParagraphSpotlightEnabled = MarkdownEditorComfortConfiguration.defaultParagraphSpotlightEnabled
  @AppStorage(MarkdownEditorComfortPreferences.automaticPreviewRefreshEnabledKey)
  private var isAutomaticPreviewRefreshEnabled = MarkdownEditorComfortConfiguration
    .defaultAutomaticPreviewRefreshEnabled
  @AppStorage(MarkdownEditorComfortPreferences.realtimeAnalysisEnabledKey)
  private var isRealtimeAnalysisEnabled = MarkdownEditorComfortConfiguration
    .defaultRealtimeAnalysisEnabled
  @AppStorage(MarkdownEditorComfortPreferences.typewriterSoundPresetKey)
  private var typewriterSoundPresetRawValue = MarkdownEditorComfortConfiguration
    .defaultTypewriterSoundPreset.rawValue
  @AppStorage("markdownEditorSynchronizedScrolling")
  private var isSynchronizedScrollingEnabled = true
  @AppStorage("markdownEditorPreviewTheme")
  private var previewThemeRawValue = MarkdownPreviewTheme.system.rawValue

  var body: some View {
    Form {
      Section {
        preferenceSlider(
          title: "字号",
          value: $fontSize,
          range: MarkdownEditorComfortConfiguration.fontSizeRange,
          step: 1,
          formattedValue: "\(Int(fontSize)) pt",
          accessibilityIdentifier: "editor-font-size"
        )

        preferenceSlider(
          title: "行距",
          value: $lineSpacing,
          range: MarkdownEditorComfortConfiguration.lineSpacingRange,
          step: 1,
          formattedValue: "\(Int(lineSpacing)) pt",
          accessibilityIdentifier: "editor-line-spacing"
        )

        preferenceSlider(
          title: "正文宽度",
          value: $bodyWidth,
          range: MarkdownEditorComfortConfiguration.bodyWidthRange,
          step: 20,
          formattedValue: "\(Int(bodyWidth)) pt",
          accessibilityIdentifier: "editor-body-width"
        )
      } header: {
        Text("文字与版式")
      } footer: {
        Text("这些值会应用到所有文章的编辑器。")
      }

      Section("编辑辅助") {
        preferenceToggle(
          title: "拼写检查",
          detail: String(localized: "在编辑器中使用 macOS 的连续拼写检查。"),
          isOn: $isSpellCheckEnabled,
          accessibilityIdentifier: "editor-spell-check"
        )
        preferenceToggle(
          title: "打字机模式（光标保持居中）",
          detail: String(localized: "输入时让当前行保持在编辑区域中央。"),
          isOn: $isTypewriterModeEnabled,
          accessibilityIdentifier: "editor-typewriter-mode"
        )
        preferenceToggle(
          title: "高亮当前段落",
          detail: String(localized: "让当前编辑段落更容易被定位。"),
          isOn: $isCurrentParagraphHighlightEnabled,
          accessibilityIdentifier: "editor-current-paragraph-highlight"
        )
        preferenceToggle(
          title: "柔和纸张背景",
          detail: String(localized: "为编辑器使用自适应的暖白或暖黑背景。"),
          isOn: $isWarmPaperBackgroundEnabled,
          accessibilityIdentifier: "editor-warm-paper-background"
        )
        preferenceToggle(
          title: "自动补全括号、引号与代码标记",
          detail: String(localized: "输入左侧符号时自动补全右侧符号；可随时撤销。"),
          isOn: $isAutomaticPairingEnabled,
          accessibilityIdentifier: "editor-automatic-pairing"
        )
        preferenceToggle(
          title: "段落焦点聚光灯（非焦点段落柔和淡出）",
          detail: String(localized: "降低非当前段落的视觉干扰。"),
          isOn: $isParagraphSpotlightEnabled,
          accessibilityIdentifier: "editor-paragraph-spotlight"
        )
      }

      Section {
        preferenceToggle(
          title: LocalizedStringKey("输入时自动刷新预览"),
          detail: String(localized: "正文、附件或预览主题变化后自动更新文章预览。"),
          isOn: $isAutomaticPreviewRefreshEnabled,
          accessibilityIdentifier: "editor-automatic-preview-refresh"
        )
        preferenceToggle(
          title: LocalizedStringKey("实时分析正文诊断与大纲"),
          detail: String(localized: "输入正文时自动更新诊断和文章大纲；关闭后仍可手动打开并分析。"),
          isOn: $isRealtimeAnalysisEnabled,
          accessibilityIdentifier: "editor-realtime-analysis"
        )
      } header: {
        Text("自动化")
      } footer: {
        Text("关闭后可使用预览中的刷新按钮，或打开诊断/大纲时手动分析。")
      }

      Section {
        Picker("打字反馈预设", selection: $typewriterSoundPresetRawValue) {
          ForEach(TypewriterSoundPreset.allCases) { preset in
            Text(preset.title).tag(preset.rawValue)
          }
        }
        .accessibilityIdentifier("editor-typewriter-feedback-preset")

        Text("选择音效后，按键会提供轻微的音效与触觉反馈。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("打字反馈")
      }

      Section {
        preferenceToggle(
          title: "编辑与预览同步滚动",
          detail: String(localized: "滚动正文时同步定位到预览对应位置。"),
          isOn: $isSynchronizedScrollingEnabled,
          accessibilityIdentifier: "editor-synchronized-scrolling"
        )

        Picker("预览主题", selection: $previewThemeRawValue) {
          ForEach(MarkdownPreviewTheme.allCases) { theme in
            Text(theme.title).tag(theme.rawValue)
          }
        }
        .accessibilityIdentifier("editor-preview-theme")

        Text("预览主题只影响编辑器内的文章预览，不会修改站点 CSS。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("预览")
      }

      Section {
        Button("恢复编辑器默认") {
          resetDefaults()
        }
        .accessibilityIdentifier("editor-reset-defaults")
      } footer: {
        Text("设置会自动保存，并在下次打开文章时继续使用。")
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.automatic)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("editor-settings")
  }

  private func preferenceSlider(
    title: LocalizedStringKey,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    formattedValue: String,
    accessibilityIdentifier: String
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
        .accessibilityIdentifier(accessibilityIdentifier)
    }
  }

  private func preferenceToggle(
    title: LocalizedStringKey,
    detail: String,
    isOn: Binding<Bool>,
    accessibilityIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(title, isOn: isOn)
        .accessibilityHint(detail)
        .accessibilityIdentifier(accessibilityIdentifier)

      Text(detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
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
    isParagraphSpotlightEnabled = MarkdownEditorComfortConfiguration.defaultParagraphSpotlightEnabled
    isAutomaticPreviewRefreshEnabled = MarkdownEditorComfortConfiguration
      .defaultAutomaticPreviewRefreshEnabled
    isRealtimeAnalysisEnabled = MarkdownEditorComfortConfiguration
      .defaultRealtimeAnalysisEnabled
    typewriterSoundPresetRawValue = MarkdownEditorComfortConfiguration.defaultTypewriterSoundPreset.rawValue
    isSynchronizedScrollingEnabled = true
    previewThemeRawValue = MarkdownPreviewTheme.system.rawValue
  }
}
