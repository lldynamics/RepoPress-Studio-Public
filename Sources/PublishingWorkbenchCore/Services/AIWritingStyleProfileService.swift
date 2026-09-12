import CryptoKit
import Foundation
import PublishingAICore
import PublishingCoreSupport

public enum AIWritingStyleProfileError: LocalizedError, Equatable, Sendable {
  case noEligibleExemplars
  case tooManyExemplars
  case selectedExemplarsUnavailable
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .noEligibleExemplars:
      return CoreL10n.text("请先选择至少一篇当前站点的公开文章作为范例。")
    case .tooManyExemplars:
      return CoreL10n.format("最多只能选择 %lld 篇写作范例。", Int64(AIWritingStyleConfig.maximumExemplarCount))
    case .selectedExemplarsUnavailable:
      return CoreL10n.text("范例文章已变化、被设为私密或不属于当前站点，请重新选择。")
    case .invalidResponse:
      return CoreL10n.text("AI 返回的写作风格档案无法安全解析，请检查后重试。")
    }
  }
}

/// A frozen, bounded selection of public same-site articles. It intentionally
/// contains no private articles and no implicit repository context.
public struct AIWritingStyleExemplarContext: Hashable, Sendable {
  public static let maximumCharacters = 8_000
  public static let maximumCharactersPerArticle = 2_000

  public let profileID: UUID
  public let articleIDs: [UUID]
  public let text: String
  /// Hashes each article's complete current title/body rather than just the
  /// transmitted excerpt, so an edit outside the bounded excerpt still makes
  /// the extraction preview stale.
  public let sourceFingerprint: String
  public let wasTruncated: Bool

  public init(
    profileID: UUID,
    articleIDs: [UUID],
    text: String,
    sourceFingerprint: String,
    wasTruncated: Bool
  ) {
    self.profileID = profileID
    self.articleIDs = articleIDs
    self.text = text
    self.sourceFingerprint = sourceFingerprint
    self.wasTruncated = wasTruncated
  }
}

/// A local preview. It is never persisted until the caller explicitly applies
/// it after revalidating the original same-site public exemplar identities.
public struct AIWritingStyleProfilePreview: Hashable, Sendable, Identifiable {
  public let id: UUID
  public let profileID: UUID
  public let exemplarArticleIDs: [UUID]
  public let style: AIWritingStyleConfig
  /// The style present when extraction began. Editing existing rules while a
  /// request is awaiting approval must invalidate the old result.
  public let baselineStyle: AIWritingStyleConfig
  public let sourceFingerprint: String
  public let sourceWasTruncated: Bool

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    exemplarArticleIDs: [UUID],
    style: AIWritingStyleConfig,
    baselineStyle: AIWritingStyleConfig,
    sourceFingerprint: String,
    sourceWasTruncated: Bool
  ) {
    self.id = id
    self.profileID = profileID
    self.exemplarArticleIDs = exemplarArticleIDs
    self.style = style
    self.baselineStyle = baselineStyle
    self.sourceFingerprint = sourceFingerprint
    self.sourceWasTruncated = sourceWasTruncated
  }
}

public struct AIWritingStyleExtractionRequest: Sendable {
  public let context: AIWritingStyleExemplarContext
  public let chatRequest: AIChatRequest

  public init(context: AIWritingStyleExemplarContext, chatRequest: AIChatRequest) {
    self.context = context
    self.chatRequest = chatRequest
  }
}

public struct AIWritingStyleProfileService: Sendable {
  public init() {}

  public func makeExtractionRequest(
    profile: SiteProfile,
    drafts: [ArticleDraft],
    selectedArticleIDs: [UUID]
  ) throws -> AIWritingStyleExtractionRequest {
    let context = try exemplarContext(
      profileID: profile.id,
      drafts: drafts,
      selectedArticleIDs: selectedArticleIDs
    )
    let existingTerms = profile.resolvedAIWritingStyle.preferredTerminology.joined(separator: "、")
    let existingAvoided = profile.resolvedAIWritingStyle.avoidedExpressions.joined(separator: "、")
    let prompt = """
      请根据下方公开文章范例提炼该站点的个人写作风格。只分析给出的范例，不要推断未提供的私人内容或仓库信息。

      仅返回一个 JSON 对象，不使用 Markdown 代码块，不添加解释。键必须是：tone、audience、summaryGuidance、tagGuidance、seoGuidance、preferredTerminology、avoidedExpressions。
      前五项均为简洁中文字符串；术语和避免表达均为字符串数组，每项不超过 80 个字符。已有优先术语：\(existingTerms.isEmpty ? "无" : existingTerms)。已有避免表达：\(existingAvoided.isEmpty ? "无" : existingAvoided)。给出补充建议即可，已有术语会由应用保留。

      公开文章范例：
      \(context.text)
      """
    let request = AIChatRequest(
      messages: [AIPublishingChatMessage(role: .user, content: prompt, contextMode: .general)],
      context: AIContextAssembler.generalEnvelope(),
      modelGrade: .standard,
      reasoningLevel: .standard
    )
    return AIWritingStyleExtractionRequest(context: context, chatRequest: request)
  }

  public func exemplarContext(
    profileID: UUID,
    drafts: [ArticleDraft],
    selectedArticleIDs: [UUID]
  ) throws -> AIWritingStyleExemplarContext {
    let uniqueIDs = unique(selectedArticleIDs)
    guard !uniqueIDs.isEmpty else { throw AIWritingStyleProfileError.noEligibleExemplars }
    guard uniqueIDs.count <= AIWritingStyleConfig.maximumExemplarCount else {
      throw AIWritingStyleProfileError.tooManyExemplars
    }
    let selectedIDs = uniqueIDs
    let byID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    let examples = selectedIDs.compactMap { byID[$0] }
    guard examples.count == selectedIDs.count,
      examples.allSatisfy({
        $0.belongs(toSiteProfileID: profileID) && !$0.isPrivate
          && !$0.bodyMarkdown.trimmedForPublishing.isEmpty
      })
    else { throw AIWritingStyleProfileError.selectedExemplarsUnavailable }

    var wasTruncated = false
    var text = ""
    for (index, draft) in examples.enumerated() {
      let separator = text.isEmpty ? "" : "\n\n"
      let remaining = AIWritingStyleExemplarContext.maximumCharacters - text.count - separator.count
      guard remaining > 0 else { throw AIWritingStyleProfileError.selectedExemplarsUnavailable }
      let headerPrefix = "范例 \(index + 1)："
      let titleLimit = min(240, max(0, remaining - headerPrefix.count - 1))
      let fullTitle = draft.title.trimmedForPublishing
      let title = String(fullTitle.prefix(titleLimit))
      wasTruncated = wasTruncated || title.count < fullTitle.count
      let header = headerPrefix + title + "\n"
      let bodyLimit = min(
        AIWritingStyleExemplarContext.maximumCharactersPerArticle, max(0, remaining - header.count))
      let body = String(draft.bodyMarkdown.trimmedForPublishing.prefix(bodyLimit))
      wasTruncated = wasTruncated || body.count < draft.bodyMarkdown.trimmedForPublishing.count
      let section = header + body
      text += separator + section
    }
    guard !text.isEmpty, text.count <= AIWritingStyleExemplarContext.maximumCharacters else {
      throw AIWritingStyleProfileError.noEligibleExemplars
    }
    return AIWritingStyleExemplarContext(
      profileID: profileID,
      articleIDs: selectedIDs,
      text: text,
      sourceFingerprint: fingerprint(for: examples),
      wasTruncated: wasTruncated
    )
  }

  public func preview(
    response: String,
    baseline: AIWritingStyleConfig,
    context: AIWritingStyleExemplarContext
  ) throws -> AIWritingStyleProfilePreview {
    let object = try JSONDecoder().decode(Response.self, from: responseData(from: response))
    guard object.hasMeaningfulContent, object.hasBoundedFields else {
      throw AIWritingStyleProfileError.invalidResponse
    }
    var style = AIWritingStyleConfig(
      preset: .custom,
      tone: object.tone ?? baseline.tone,
      audience: object.audience ?? baseline.audience,
      summaryGuidance: object.summaryGuidance ?? baseline.summaryGuidance,
      tagGuidance: object.tagGuidance ?? baseline.tagGuidance,
      seoGuidance: object.seoGuidance ?? baseline.seoGuidance,
      preferredTerminology: merged(
        baseline.preferredTerminology, object.preferredTerminology ?? []),
      avoidedExpressions: merged(baseline.avoidedExpressions, object.avoidedExpressions ?? []),
      exemplarArticleIDs: context.articleIDs
    )
    style.normalizeWhitespace()
    return AIWritingStyleProfilePreview(
      profileID: context.profileID,
      exemplarArticleIDs: context.articleIDs,
      style: style,
      baselineStyle: baseline,
      sourceFingerprint: context.sourceFingerprint,
      sourceWasTruncated: context.wasTruncated
    )
  }

  /// Returns nil instead of silently applying when the selection has become
  /// stale or crosses a privacy/site boundary since extraction began.
  public func validatedPreview(
    _ preview: AIWritingStyleProfilePreview,
    profile: SiteProfile,
    drafts: [ArticleDraft]
  ) -> AIWritingStyleProfilePreview? {
    guard preview.profileID == profile.id,
      preview.baselineStyle == profile.resolvedAIWritingStyle,
      let currentContext = try? exemplarContext(
        profileID: profile.id,
        drafts: drafts,
        selectedArticleIDs: preview.exemplarArticleIDs
      ), currentContext.sourceFingerprint == preview.sourceFingerprint
    else { return nil }
    return preview
  }

  private func responseData(from text: String) throws -> Data {
    let trimmed = text.trimmedForPublishing
    guard trimmed.count <= 16_000 else { throw AIWritingStyleProfileError.invalidResponse }
    let json =
      trimmed
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmedForPublishing
    guard let data = json.data(using: .utf8) else {
      throw AIWritingStyleProfileError.invalidResponse
    }
    return data
  }

  private func unique(_ values: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return values.filter { seen.insert($0).inserted }
  }

  private func merged(_ baseline: [String], _ inferred: [String]) -> [String] {
    var result = baseline
    for term in inferred where !result.contains(term) {
      result.append(term)
    }
    return result
  }

  private func fingerprint(for drafts: [ArticleDraft]) -> String {
    let text = drafts.map {
      "\($0.id.uuidString)\u{1F}\($0.title)\u{1F}\($0.bodyMarkdown)\u{1F}\($0.visibility.rawValue)"
    }.joined(separator: "\u{1E}")
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private struct Response: Decodable {
    let tone: String?
    let audience: String?
    let summaryGuidance: String?
    let tagGuidance: String?
    let seoGuidance: String?
    let preferredTerminology: [String]?
    let avoidedExpressions: [String]?

    var hasMeaningfulContent: Bool {
      [tone, audience, summaryGuidance, tagGuidance, seoGuidance]
        .contains { !$0.orEmpty.trimmedForPublishing.isEmpty }
        || preferredTerminology?.contains(where: { !$0.trimmedForPublishing.isEmpty }) == true
        || avoidedExpressions?.contains(where: { !$0.trimmedForPublishing.isEmpty }) == true
    }

    var hasBoundedFields: Bool {
      [tone, audience, summaryGuidance, tagGuidance, seoGuidance]
        .allSatisfy { ($0?.count ?? 0) <= AIWritingStyleConfig.maximumRuleCharacterCount }
        && (preferredTerminology ?? []).allSatisfy {
          $0.count <= AIWritingStyleConfig.maximumTerminologyCharacterCount
        }
        && (avoidedExpressions ?? []).allSatisfy {
          $0.count <= AIWritingStyleConfig.maximumTerminologyCharacterCount
        }
    }
  }
}

extension Optional where Wrapped == String {
  fileprivate var orEmpty: String { self ?? "" }
}
