import PublishingWorkbenchCore
import SwiftUI

struct RSSArticleTranslationControls: View {
  let translation: RSSArticleTranslationResult?
  @Binding var targetCode: String
  @Binding var customLanguage: String
  @Binding var automaticTranslation: Bool
  let isTranslating: Bool
  let isShowingTranslation: Bool
  let onTranslate: () -> Void
  let onToggleDisplay: () -> Void
  let onClear: () -> Void
  let dataSharingConsent: AIDataSharingConsentPresentation
  let onOpenAISettings: () -> Void

  @State private var isCustomLanguagePresented = false

  var body: some View {
    Menu {
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
      }

      Divider()

      Toggle("打开文章时自动翻译", isOn: $automaticTranslation)
      Text("自动翻译会将当前文章标题和正文发送给当前 AI 服务。")
        .font(.caption)
        .foregroundStyle(.secondary)

      Divider()

      Button {
        onTranslate()
      } label: {
        Label(
          isTranslating
            ? "正在翻译…"
            : (translation == nil ? "翻译标题和正文" : "重新翻译标题和正文"),
          systemImage: isTranslating ? "hourglass" : "character.book.closed"
        )
      }
      .disabled(isTranslating)
      .keyboardShortcut("t", modifiers: [.command, .option])

      if translation != nil {
        Button(
          isShowingTranslation ? "显示原文" : "显示译文",
          systemImage: isShowingTranslation ? "doc.plaintext" : "character.book.closed",
          action: onToggleDisplay
        )
        Button("清除译文", systemImage: "xmark.circle", action: onClear)
      }

      Divider()
      Section("发送权限") {
        Text(consentSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("管理 AI 发送权限", systemImage: "gearshape", action: onOpenAISettings)
      }
    } label: {
      Label("翻译", systemImage: "character.book.closed")
    }
    .menuStyle(.button)
    .help("选择目标语言，并手动或自动翻译当前 RSS 文章")
    .accessibilityLabel("翻译 RSS 文章")
    .accessibilityHint("选择目标语言、翻译标题和正文，或管理 AI 发送权限")
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
