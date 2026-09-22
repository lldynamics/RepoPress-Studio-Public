import PublishingAICore
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

extension RSSArticleList {
  var listTranslationBackend: RSSArticleTranslationBackend {
    RSSArticleTranslationBackend(rawValue: titleTranslationBackendRawValue)
      ?? RSSReaderUserPreferences.defaultTranslationBackend
  }

  var listTranslationTarget: RSSArticleTranslationTarget {
    RSSArticleTranslationTarget.preset(for: titleTranslationTargetCode)
      ?? RSSArticleTranslationTarget.custom(language: titleTranslationCustomLanguage)
      ?? .simplifiedChinese
  }

  var titleTranslationProviderIdentity: Int {
    listTranslationBackend == .ai ? aiConfiguration().hashValue : 0
  }

  var titleTranslationInput: RSSListTitleTranslationInput {
    RSSListTitleTranslationInput(
      enabled: automaticTitleTranslationEnabled && ai.canUseProtectedWorkbench,
      titles: (preparedList?.visibleArticles ?? []).map {
        RSSArticleTranslationTextRequest(id: $0.id, sourceText: $0.title)
      },
      target: listTranslationTarget,
      backend: listTranslationBackend,
      providerIdentity: titleTranslationProviderIdentity,
      consent: listTranslationBackend == .ai ? ai.dataSharingConsent : nil,
      retryRevision: titleTranslationRetryRevision
    )
  }

  func translatedListTitle(for article: RSSArticleHeader) -> String? {
    guard automaticTitleTranslationEnabled else { return nil }
    return titleTranslator.translatedTitle(
      id: article.id, source: article.title, target: listTranslationTarget,
      backend: listTranslationBackend, providerIdentity: titleTranslationProviderIdentity)
  }

  func translateListTitles(_ input: RSSListTitleTranslationInput) async {
    // Let rapid filter changes settle before contacting a provider.
    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
    await titleTranslator.run(input) { titles in
      switch input.backend {
      case .apple:
        return try await titleAppleBridge.translate(titles, target: input.target)
      case .ai:
        let translations = try await ai.translateRSSTitles(titles, target: input.target)
        return RSSListTitleTranslationBatchResult(translations: translations)
      }
    }
  }

  var listTitleTranslationMenu: some View {
    Menu {
      Toggle("自动翻译列表标题", isOn: $automaticTitleTranslationEnabled)
        .accessibilityIdentifier("rss-list-automatic-title-translation")
      Text(
        listTranslationBackend == .apple
          ? String(localized: "只翻译当前已加载列表中的标题；需要已安装对应语言包，不会自动下载。")
          : String(localized: "只翻译当前已加载列表中的标题；仅在已允许 AI 发送权限时使用，不会发送正文。"))
      Divider()
      Picker("翻译引擎", selection: $titleTranslationBackendRawValue) {
        Text("Apple 本机翻译").tag(RSSArticleTranslationBackend.apple.rawValue)
          .disabled(!RSSReaderUserPreferences.isAppleTranslationAvailable)
        Text("当前 AI 服务").tag(RSSArticleTranslationBackend.ai.rawValue)
      }
      Menu("目标语言") {
        ForEach(RSSArticleTranslationTarget.presets) { target in
          Button {
            titleTranslationTargetCode = target.languageCode
            titleTranslationCustomLanguage = ""
          } label: {
            Label(
              listTargetName(target),
              systemImage: titleTranslationTargetCode == target.languageCode
                ? "checkmark" : "character")
          }
        }
      }
    } label: {
      Label("翻译", systemImage: "character.book.closed")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("自动翻译列表标题")
    .accessibilityValue(automaticTitleTranslationEnabled ? "开启" : "关闭")
    .accessibilityIdentifier("rss-list-title-translation-menu")
  }

  @ViewBuilder
  var listTitleTranslationStatus: some View {
    if automaticTitleTranslationEnabled {
      if titleTranslator.isRunning {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("正在翻译列表标题…").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else if let issue = titleTranslator.issue {
        HStack(alignment: .top, spacing: 8) {
          Label("部分标题未翻译，已保留原文", systemImage: "info.circle")
            .help(issue)
            .accessibilityHint(issue)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("重试") { titleTranslationRetryRevision += 1 }
            .buttonStyle(.borderless)
            .accessibilityLabel("重试翻译列表标题")
        }
      }
    }
  }

  private func listTargetName(_ target: RSSArticleTranslationTarget) -> String {
    switch target.languageCode {
    case "zh-Hans": return String(localized: "简体中文")
    case "zh-Hant": return String(localized: "繁体中文")
    case "en": return String(localized: "English")
    case "ja": return String(localized: "日语")
    case "ko": return String(localized: "韩语")
    case "es": return String(localized: "西班牙语")
    case "fr": return String(localized: "法语")
    case "de": return String(localized: "德语")
    default: return String(localized: "目标语言")
    }
  }
}
