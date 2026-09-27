import SwiftUI

/// Application-wide editor preferences.
///
/// The single complete editor appearance surface. The Aa toolbar button opens
/// this page, while writing modes remain in the editor's focus menu.
struct EditorSettingsView: View {
  @AppStorage(MarkdownEditorComfortPreferences.bodyFontStyleKey)
  private var bodyFontStyleRawValue = MarkdownEditorBodyFontStyle.defaultStyle.rawValue
  @AppStorage(MarkdownEditorComfortPreferences.fontSizeKey)
  private var fontSize = MarkdownEditorComfortConfiguration.defaultFontSize
  @AppStorage(MarkdownEditorComfortPreferences.lineSpacingKey)
  private var lineSpacing = MarkdownEditorComfortConfiguration.defaultLineSpacing
  @AppStorage(MarkdownEditorComfortPreferences.bodyWidthKey)
  private var bodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
  @AppStorage(MarkdownEditorComfortPreferences.spellCheckEnabledKey)
  private var isSpellCheckEnabled = MarkdownEditorComfortConfiguration.defaultSpellCheckEnabled
  @AppStorage(MarkdownEditorComfortPreferences.warmPaperBackgroundEnabledKey)
  private var isWarmPaperBackgroundEnabled = MarkdownEditorComfortConfiguration
    .defaultWarmPaperBackgroundEnabled
  @AppStorage(MarkdownEditorComfortPreferences.automaticPairingEnabledKey)
  private var isAutomaticPairingEnabled = MarkdownEditorComfortConfiguration
    .defaultAutomaticPairingEnabled
  @AppStorage(MarkdownEditorComfortPreferences.realtimeAnalysisEnabledKey)
  private var isRealtimeAnalysisEnabled = MarkdownEditorComfortConfiguration
    .defaultRealtimeAnalysisEnabled

  var body: some View {
    Form {
      previewSection
      typographySection
      assistanceSection
      automationSection
      EditorArticleDefaultsSection()
    }
    .formStyle(.grouped)
    .padding(WorkbenchSpacing.content)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("editor-settings")
  }

  private var previewSection: some View {
    Section {
      editorLivePreviewCard
    } header: {
      Text("排版效果实时预览")
        .settingsSubsectionAnchor(.editorPreview)
    } footer: {
      Text("拖动下方滑块或切换开关，此处会即时呈现文章在编辑器内的排版与视觉氛围。")
    }
  }

  private var typographySection: some View {
    Section {
      Picker("正文字体", selection: $bodyFontStyleRawValue) {
        ForEach(MarkdownEditorBodyFontStyle.allCases) { style in
          Text(style.title).tag(style.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .help("代码与代码块始终使用等宽字体。")
      .accessibilityIdentifier("editor-body-font-style")

      preferenceSlider(
        title: "字号",
        value: $fontSize,
        range: MarkdownEditorComfortConfiguration.fontSizeRange,
        step: 1,
        defaultValue: MarkdownEditorComfortConfiguration.defaultFontSize,
        formattedValue: "\(Int(fontSize)) pt",
        accessibilityIdentifier: "editor-font-size"
      )

      preferenceSlider(
        title: "行距",
        value: $lineSpacing,
        range: MarkdownEditorComfortConfiguration.lineSpacingRange,
        step: 1,
        defaultValue: MarkdownEditorComfortConfiguration.defaultLineSpacing,
        formattedValue: "\(Int(lineSpacing)) pt",
        accessibilityIdentifier: "editor-line-spacing"
      )

      preferenceSlider(
        title: "正文宽度",
        value: $bodyWidth,
        range: MarkdownEditorComfortConfiguration.bodyWidthRange,
        step: 20,
        defaultValue: MarkdownEditorComfortConfiguration.defaultBodyWidth,
        formattedValue: "\(Int(bodyWidth)) pt",
        accessibilityIdentifier: "editor-body-width"
      )
    } header: {
      Text("文字与版式")
        .settingsSubsectionAnchor(.editorTypography)
    } footer: {
      Text("这些值会应用到所有文章的编辑器。")
    }
  }

  private var assistanceSection: some View {
    Section {
      preferenceToggle(
        title: "拼写检查",
        detail: String(localized: "在编辑器中使用 macOS 的连续拼写检查。"),
        isOn: $isSpellCheckEnabled,
        accessibilityIdentifier: "editor-spell-check"
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
    } header: {
      Text("编辑辅助")
        .settingsSubsectionAnchor(.editorAssistance)
    }
  }

  private var automationSection: some View {
    Group {
      Section {
        preferenceToggle(
          title: LocalizedStringKey("实时分析正文诊断与大纲"),
          detail: String(localized: "输入正文时自动更新诊断和文章大纲；关闭后仍可手动打开并分析。"),
          isOn: $isRealtimeAnalysisEnabled,
          accessibilityIdentifier: "editor-realtime-analysis"
        )
      } header: {
        Text("自动化")
          .settingsSubsectionAnchor(.editorAutomation)
      } footer: {
        Text("关闭后仍可在打开诊断或大纲时手动分析。")
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
  }

  private func preferenceSlider(
    title: LocalizedStringKey,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    defaultValue: Double,
    formattedValue: String,
    accessibilityIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center) {
        Text(title)

        if value.wrappedValue != defaultValue {
          Button {
            value.wrappedValue = defaultValue
          } label: {
            Image(systemName: "arrow.counterclockwise")
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("恢复默认值 \(Int(defaultValue)) pt")
          .accessibilityLabel(
            Text(
              String(
                format: String(localized: "恢复默认值 %lld pt"),
                Int64(defaultValue)
              )
            )
          )
        }

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

  private var editorLivePreviewCard: some View {
    VStack(alignment: .leading, spacing: CGFloat(lineSpacing) + 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("晨光中的写作与思考")
          .font(previewTitleFont)
          .foregroundStyle(.primary)

        Spacer()

        HStack(spacing: 6) {
          if isWarmPaperBackgroundEnabled {
            previewTag(title: "暖纸", icon: "sun.max")
          }
        }
      }
      .padding(.bottom, 2)

      Text("清晰的排版如同清晨微风，使阅读与创作自然流淌。当字号与行距恰到好处时，文字便拥有了呼吸的节奏。")
        .font(previewBodyFont)
        .fontDesign(previewBodyFontDesign)
        .lineSpacing(CGFloat(lineSpacing))
        .foregroundStyle(.primary)

      Text("合适的字体与留白，让长篇写作更舒适。代码与代码块始终使用等宽字体。")
        .font(previewBodyFont)
        .fontDesign(previewBodyFontDesign)
        .lineSpacing(CGFloat(lineSpacing))
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("排版效果实时预览")
  }

  private var boundedPreviewFontSize: Double {
    let range = MarkdownEditorComfortConfiguration.fontSizeRange
    return min(max(fontSize, range.lowerBound), range.upperBound)
  }

  private var previewTitleFont: Font {
    switch boundedPreviewFontSize {
    case ..<14:
      return .body.weight(.bold)
    case ..<18:
      return .title3.weight(.bold)
    case ..<22:
      return .title2.weight(.bold)
    default:
      return .title.weight(.bold)
    }
  }

  private var previewBodyFontDesign: Font.Design {
    MarkdownEditorBodyFontStyle.resolved(rawValue: bodyFontStyleRawValue).previewDesign
  }

  private var previewBodyFont: Font {
    switch boundedPreviewFontSize {
    case ..<14:
      return .callout
    case ..<18:
      return .body
    case ..<22:
      return .title3
    default:
      return .title2
    }
  }

  private func previewTag(title: String, icon: String) -> some View {
    Label(title, systemImage: icon)
      .font(.workbenchMetadata.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(0.06), in: Capsule())
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
    UserDefaults.standard.set(
      MarkdownEditorComfortConfiguration.defaultParagraphFocusEnabled,
      forKey: MarkdownEditorComfortPreferences.paragraphFocusEnabledKey
    )
    bodyFontStyleRawValue = MarkdownEditorBodyFontStyle.defaultStyle.rawValue
    fontSize = MarkdownEditorComfortConfiguration.defaultFontSize
    lineSpacing = MarkdownEditorComfortConfiguration.defaultLineSpacing
    bodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
    isSpellCheckEnabled = MarkdownEditorComfortConfiguration.defaultSpellCheckEnabled
    isWarmPaperBackgroundEnabled =
      MarkdownEditorComfortConfiguration.defaultWarmPaperBackgroundEnabled
    isAutomaticPairingEnabled = MarkdownEditorComfortConfiguration.defaultAutomaticPairingEnabled
    isRealtimeAnalysisEnabled =
      MarkdownEditorComfortConfiguration
      .defaultRealtimeAnalysisEnabled
  }
}
