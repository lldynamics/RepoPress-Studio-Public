import Foundation
import PublishingCoreSupport

/// A user-selected language for RSS article translation.
public struct RSSArticleTranslationTarget: Codable, Hashable, Identifiable, Sendable {
  public let languageCode: String
  public let displayName: String

  public var id: String { languageCode }

  public init(languageCode: String, displayName: String) {
    self.languageCode = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
    self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static let simplifiedChinese = Self(
    languageCode: "zh-Hans",
    displayName: "Simplified Chinese"
  )
  public static let traditionalChinese = Self(
    languageCode: "zh-Hant",
    displayName: "Traditional Chinese"
  )
  public static let english = Self(languageCode: "en", displayName: "English")
  public static let japanese = Self(languageCode: "ja", displayName: "Japanese")
  public static let korean = Self(languageCode: "ko", displayName: "Korean")
  public static let spanish = Self(languageCode: "es", displayName: "Spanish")
  public static let french = Self(languageCode: "fr", displayName: "French")
  public static let german = Self(languageCode: "de", displayName: "German")

  public static let presets: [Self] = [
    .simplifiedChinese,
    .traditionalChinese,
    .english,
    .japanese,
    .korean,
    .spanish,
    .french,
    .german,
  ]

  public static func preset(for languageCode: String) -> Self? {
    let normalizedCode = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
    return presets.first { $0.languageCode == normalizedCode }
  }

  public static func custom(language: String) -> Self? {
    let normalizedLanguage =
      language
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    guard !normalizedLanguage.isEmpty else { return nil }
    let code =
      "custom:\(normalizedLanguage.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    return Self(languageCode: code, displayName: normalizedLanguage)
  }
}

public struct RSSArticleTranslationResult: Hashable, Sendable, Identifiable {
  public let revision: UUID
  public let articleID: String
  public let target: RSSArticleTranslationTarget
  public let translatedTitle: String
  public let translatedContentHTML: String
  public let providerName: String
  public let model: String
  public let sourceCharacterCount: Int
  public let wasInputTruncated: Bool

  public var id: String {
    revision.uuidString
  }

  public init(
    revision: UUID = UUID(),
    articleID: String,
    target: RSSArticleTranslationTarget,
    translatedTitle: String,
    translatedContentHTML: String,
    providerName: String,
    model: String,
    sourceCharacterCount: Int,
    wasInputTruncated: Bool
  ) {
    self.revision = revision
    self.articleID = articleID
    self.target = target
    self.translatedTitle = translatedTitle
    self.translatedContentHTML = translatedContentHTML
    self.providerName = providerName
    self.model = model
    self.sourceCharacterCount = sourceCharacterCount
    self.wasInputTruncated = wasInputTruncated
  }

  /// Reuses the original article's identity and metadata while replacing only
  /// the title and body shown in the reader. The existing HTML renderer still
  /// sanitizes the translated result before it reaches WebKit.
  public func applying(to article: RSSArticle) -> RSSArticle {
    var translated = article
    translated.title = translatedTitle
    translated.summaryHTML = translatedContentHTML
    translated.contentHTML = translatedContentHTML
    return translated
  }
}

public enum RSSArticleTranslationError: LocalizedError, Equatable, Sendable {
  case emptyArticle
  case invalidResponse
  case protectedWorkbenchUnavailable

  public var errorDescription: String? {
    switch self {
    case .emptyArticle:
      return CoreL10n.text("这篇文章没有可翻译的本地正文。")
    case .invalidResponse:
      return CoreL10n.text("翻译服务返回的内容无法安全解析，请稍后重试。")
    case .protectedWorkbenchUnavailable:
      return CoreL10n.text("快速隐藏已启用，请返回工作台后再继续翻译。")
    }
  }
}

public enum RSSArticleTranslationResponseParser {
  private struct Payload: Decodable {
    let title: String
    let contentHTML: String

    private enum CodingKeys: String, CodingKey {
      case title
      case contentHTML = "content_html"
      case legacyContentHTML = "contentHTML"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(String.self, forKey: .title)
      contentHTML =
        try container.decodeIfPresent(String.self, forKey: .contentHTML)
        ?? container.decode(String.self, forKey: .legacyContentHTML)
    }
  }

  public static func parse(
    _ content: String,
    articleID: String,
    target: RSSArticleTranslationTarget,
    providerName: String,
    model: String,
    sourceCharacterCount: Int,
    wasInputTruncated: Bool
  ) -> RSSArticleTranslationResult? {
    let candidate = jsonCandidate(from: content)
    guard let data = candidate.data(using: .utf8),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else {
      return nil
    }

    let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let contentHTML = payload.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !contentHTML.isEmpty else { return nil }
    return RSSArticleTranslationResult(
      articleID: articleID,
      target: target,
      translatedTitle: title,
      translatedContentHTML: contentHTML,
      providerName: providerName,
      model: model,
      sourceCharacterCount: sourceCharacterCount,
      wasInputTruncated: wasInputTruncated
    )
  }

  private static func jsonCandidate(from content: String) -> String {
    var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
      if let firstNewline = trimmed.firstIndex(of: "\n") {
        trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
      }
      if let closingFence = trimmed.range(of: "```", options: .backwards) {
        trimmed = String(trimmed[..<closingFence.lowerBound])
      }
      trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let firstBrace = trimmed.firstIndex(of: "{"),
      let lastBrace = trimmed.lastIndex(of: "}"),
      firstBrace <= lastBrace
    else {
      return trimmed
    }
    return String(trimmed[firstBrace...lastBrace])
  }
}
