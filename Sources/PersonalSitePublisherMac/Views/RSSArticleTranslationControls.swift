import PublishingWorkbenchCore
import SwiftUI

struct RSSArticleTranslationControls: View {
  let translation: RSSArticleTranslationResult?
  @Binding var translationBackend: RSSArticleTranslationBackend
  @Binding var targetCode: String
  @Binding var customLanguage: String
  @Binding var automaticTranslation: Bool
  let isAppleTranslationAvailable: Bool
  let isTranslating: Bool
  let isShowingTranslation: Bool
  let onTranslate: (RSSArticleTranslationBackend) -> Void
  let onToggleDisplay: () -> Void
  let onClear: () -> Void
  let dataSharingConsent: AIDataSharingConsentPresentation
  let onOpenAISettings: () -> Void

  @State private var isCustomLanguagePresented = false

  var body: some View {
    Menu {
      Section("翻译引擎") {
        Picker("翻译引擎", selection: translationBackendSelection) {
          Text("Apple 本机翻译")
            .tag(RSSArticleTranslationBackend.apple)
            .disabled(!isAppleTranslationAvailable)
          Text("当前 AI 服务")
            .tag(RSSArticleTranslationBackend.ai)
        }
        .accessibilityLabel("翻译引擎")
        .accessibilityValue(translationBackendName)
        .accessibilityHint(translationBackendHint)

        Text(translationBackendDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      Section("目标语言") {
        ForEach(RSSArticleTranslationTarget.presets) { target in
          Button {
            targetCode = target.languageCode
            customLanguage = ""
          } label: {
            Label(
              localizedName(for: target),
              systemImage: targetCode == target.languageCode ? "checkmark" : "character"
            )
          }
        }
        if translationBackend == .ai {
          if targetCode.hasPrefix("custom:"), !customLanguage.isEmpty {
            Button {
              isCustomLanguagePresented = true
            } label: {
              Label(customLanguage, systemImage: "checkmark")
            }
          }
          Button("自定义语言…", systemImage: "pencil") {
            isCustomLanguagePresented = true
          }
        } else {
          Text("自定义语言仅适用于当前 AI 服务；Apple 本机翻译请从预设语言中选择。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Divider()

      Toggle("打开文章时自动翻译", isOn: $automaticTranslation)
        .accessibilityValue(automaticTranslation ? "开启" : "关闭")
        .accessibilityHint(automaticTranslationDescription)
      Text(automaticTranslationDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      Button {
        onTranslate(translationBackend)
      } label: {
        Label(
          translationActionTitle,
          systemImage: isTranslating ? "hourglass" : "character.book.closed"
        )
      }
      .disabled(isTranslating)
      .keyboardShortcut("t", modifiers: [.command, .option])
      .accessibilityValue(translationBackendName)
      .accessibilityHint("按当前翻译引擎处理标题和正文")

      if translation != nil {
        Button(
          displayActionTitle,
          systemImage: isShowingTranslation ? "doc.plaintext" : "character.book.closed",
          action: onToggleDisplay
        )
        Button("清除译文", systemImage: "xmark.circle", action: onClear)
      }

      if translationBackend == .ai {
        Divider()
        Section("发送权限") {
          Text(consentSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("管理 AI 发送权限", systemImage: "gearshape", action: onOpenAISettings)
        }
      }
    } label: {
      Label("翻译", systemImage: "character.book.closed")
    }
    .menuStyle(.button)
    .help("选择翻译引擎和目标语言，并手动或自动翻译当前 RSS 文章")
    .accessibilityLabel("翻译 RSS 文章")
    .accessibilityValue(translationBackendName)
    .accessibilityHint(translationBackendHint)
    .onAppear(perform: normalizeAppleTargetIfNeeded)
    .onChange(of: translationBackend) { _, _ in
      normalizeAppleTargetIfNeeded()
    }
    .sheet(isPresented: $isCustomLanguagePresented) {
      RSSArticleTranslationLanguageSheet(
        initialLanguage: customLanguage,
        onSave: { language in
          guard let target = RSSArticleTranslationTarget.custom(language: language) else {
            return
          }
          customLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
          targetCode = target.languageCode
        }
      )
    }
  }

  private var translationBackendSelection: Binding<RSSArticleTranslationBackend> {
    Binding(
      get: { translationBackend },
      set: { backend in
        guard backend != .apple || isAppleTranslationAvailable else { return }
        translationBackend = backend
        if backend == .apple, targetCode.hasPrefix("custom:") {
          targetCode = RSSArticleTranslationTarget.simplifiedChinese.languageCode
          customLanguage = ""
        }
      }
    )
  }

  private func normalizeAppleTargetIfNeeded() {
    guard translationBackend == .apple, targetCode.hasPrefix("custom:") else { return }
    targetCode = RSSArticleTranslationTarget.simplifiedChinese.languageCode
    customLanguage = ""
  }

  private var translationBackendName: String {
    switch translationBackend {
    case .apple:
      return String(localized: "Apple 本机翻译")
    case .ai:
      return String(localized: "当前 AI 服务")
    }
  }

  private var translationBackendDescription: String {
    switch translationBackend {
    case .apple where isAppleTranslationAvailable:
      return String(localized: "标题和正文在设备端处理，不会发送给 AI；首次使用某种语言时，Apple 可能要求下载语言包。")
    case .apple:
      return String(localized: "Apple 本机翻译在 macOS 14 不可用，请选择当前 AI 服务。")
    case .ai:
      return String(localized: "当前 AI 服务会发送文章标题和正文，并受发送权限约束。")
    }
  }

  private var automaticTranslationDescription: String {
    switch translationBackend {
    case .apple:
      return String(localized: "Apple 本机翻译只会在目标语言包已安装时自动翻译；未安装时不会自动下载或弹出提示，标题和正文在本机设备端处理。")
    case .ai:
      return String(localized: "自动翻译会将当前文章标题和正文发送给当前 AI 服务，并受发送权限约束。")
    }
  }

  private var translationBackendHint: String {
    switch translationBackend {
    case .apple:
      return String(localized: "标题和正文仅在本机处理，不需要 AI 发送授权。")
    case .ai:
      return String(localized: "标题和正文会按当前 AI 发送权限发送给 AI 服务。")
    }
  }

  private var translationActionTitle: String {
    if isTranslating {
      return String(localized: "正在翻译…")
    }
    return translation == nil
      ? String(localized: "翻译标题和正文")
      : String(localized: "重新翻译标题和正文")
  }

  private var displayActionTitle: String {
    isShowingTranslation
      ? String(localized: "显示原文")
      : String(localized: "显示译文")
  }

  private var consentSummary: String {
    switch dataSharingConsent.destinationState {
    case .local:
      return "仅发送到本机 AI 服务；范围：当前文章标题和正文。"
    case .remote:
      if dataSharingConsent.isGranted {
        return "已允许发送给 \(dataSharingConsent.providerName)（\(dataSharingConsent.destination)）；范围：当前文章标题和正文。"
      }
      return "远程 AI 发送尚未授权；翻译前需先确认服务商和发送范围。"
    case .unconfigured:
      return "尚未配置 AI 翻译服务；请先在 AI 设置中配置。"
    }
  }

  private func localizedName(for target: RSSArticleTranslationTarget) -> String {
    switch target.languageCode {
    case RSSArticleTranslationTarget.simplifiedChinese.languageCode:
      return String(localized: "简体中文")
    case RSSArticleTranslationTarget.traditionalChinese.languageCode:
      return String(localized: "繁体中文")
    case RSSArticleTranslationTarget.english.languageCode:
      return String(localized: "English")
    case RSSArticleTranslationTarget.japanese.languageCode:
      return String(localized: "日语")
    case RSSArticleTranslationTarget.korean.languageCode:
      return String(localized: "韩语")
    case RSSArticleTranslationTarget.spanish.languageCode:
      return String(localized: "西班牙语")
    case RSSArticleTranslationTarget.french.languageCode:
      return String(localized: "法语")
    case RSSArticleTranslationTarget.german.languageCode:
      return String(localized: "德语")
    default:
      return customLanguage.isEmpty ? target.languageCode : customLanguage
    }
  }
}

private struct RSSArticleTranslationLanguageSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var language: String
  @State private var validationMessage: String?
  let onSave: (String) -> Void

  init(initialLanguage: String, onSave: @escaping (String) -> Void) {
    _language = State(initialValue: initialLanguage)
    self.onSave = onSave
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("自定义目标语言")
        .font(.title3.weight(.semibold))
      Text("输入语言名称或地区变体，例如“葡萄牙语（巴西）”。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("目标语言", text: $language)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("目标语言")
        .onSubmit(save)
      if let validationMessage {
        Text(validationMessage)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.risk)
      }
      HStack {
        Spacer()
        Button("取消", action: { dismiss() })
          .keyboardShortcut(.cancelAction)
        Button("保存", action: save)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(RSSArticleTranslationTarget.custom(language: language) == nil)
      }
    }
    .padding(24)
    .frame(width: 420)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("自定义 RSS 翻译目标语言")
  }

  private func save() {
    guard RSSArticleTranslationTarget.custom(language: language) != nil else {
      validationMessage = String(localized: "请输入目标语言。")
      return
    }
    onSave(language)
    dismiss()
  }
}
