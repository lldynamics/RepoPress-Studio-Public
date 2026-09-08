import Foundation
import NaturalLanguage
import PublishingKnowledgeCore

/// Presentation-only grouping for the article Inspector. Retrieval deliberately
/// remains unchanged; this stops one source document from consuming the first
/// several recommendation cards with adjacent chunks.
struct KnowledgeContextRecommendationPresentation: Identifiable, Sendable {
  let document: KnowledgeDocument
  let primaryResult: KnowledgeSearchResult
  let additionalResults: [KnowledgeSearchResult]
  let reason: String

  var id: UUID { document.id }
}

struct KnowledgeContextRecommendationPresentationGroups: Sendable {
  let strong: [KnowledgeContextRecommendationPresentation]
  let possible: [KnowledgeContextRecommendationPresentation]

  static let empty = KnowledgeContextRecommendationPresentationGroups(strong: [], possible: [])
}

/// The complete, immutable data required to render one Inspector update. It is
/// deliberately bounded by the retrieval limit and is produced away from the
/// view graph, so SwiftUI updates do not repeat tokenization or snippet work.
struct KnowledgeContextRecommendationPresentationSnapshot: Sendable {
  let query: String
  let groups: KnowledgeContextRecommendationPresentationGroups
  let hitsByResultID: [UUID: KnowledgeSearchHitPresentation]
  let semanticRecommendationCount: Int
  let classifiedResultCount: Int

  static func empty(query: String) -> Self {
    Self(
      query: query,
      groups: .empty,
      hitsByResultID: [:],
      semanticRecommendationCount: 0,
      classifiedResultCount: 0
    )
  }
}

/// The content-sensitive input identity used by the presentation coordinator.
/// `KnowledgeSearchResult` carries document/chunk revision and content data, so
/// a new indexed result invalidates the one retained snapshot.
struct KnowledgeContextRecommendationPresentationInput: Hashable, Sendable {
  let query: String
  let results: [KnowledgeSearchResult]
  let excludingDocumentIDs: Set<UUID>
}

enum KnowledgeContextRecommendationPresentationPolicy {
  static func groups(
    from results: [KnowledgeSearchResult],
    query: String,
    excludingDocumentIDs: Set<UUID> = [],
    maximumDocumentCount: Int = 4
  ) -> KnowledgeContextRecommendationPresentationGroups {
    let classified = classifiedResults(
      from: results,
      queryTerms: specificQueryTerms(in: query),
      excludingDocumentIDs: excludingDocumentIDs
    )
    return groups(from: classified, maximumDocumentCount: maximumDocumentCount)
  }

  static func cards(
    from results: [KnowledgeSearchResult],
    query: String,
    excludingDocumentIDs: Set<UUID> = [],
    maximumDocumentCount: Int = 4,
    strength: Strength = .strong
  ) -> [KnowledgeContextRecommendationPresentation] {
    guard maximumDocumentCount > 0 else { return [] }
    let classified = classifiedResults(
      from: results,
      queryTerms: specificQueryTerms(in: query),
      excludingDocumentIDs: excludingDocumentIDs
    )
    return cards(
      from: classified,
      maximumDocumentCount: maximumDocumentCount,
      strength: strength
    )
  }

  static func snapshot(
    for input: KnowledgeContextRecommendationPresentationInput
  ) -> KnowledgeContextRecommendationPresentationSnapshot? {
    guard !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .empty(query: input.query)
    }

    let classified = classifiedResults(
      from: input.results,
      queryTerms: specificQueryTerms(in: input.query),
      excludingDocumentIDs: input.excludingDocumentIDs
    )
    guard !Task.isCancelled else { return nil }

    let groups = groups(from: classified, maximumDocumentCount: 4)
    let renderedResults = (groups.strong + groups.possible).flatMap {
      [$0.primaryResult] + $0.additionalResults
    }
    var hitsByResultID = [UUID: KnowledgeSearchHitPresentation]()
    hitsByResultID.reserveCapacity(renderedResults.count)
    let presentationService = KnowledgeSearchPresentationService()
    for result in renderedResults {
      guard !Task.isCancelled else { return nil }
      hitsByResultID[result.id] = presentationService.presentation(
        for: result,
        query: input.query,
        maximumSnippetCharacters: 210
      )
    }

    return KnowledgeContextRecommendationPresentationSnapshot(
      query: input.query,
      groups: groups,
      hitsByResultID: hitsByResultID,
      semanticRecommendationCount: groups.strong.filter {
        $0.primaryResult.signals.contains(.semantic)
      }.count,
      classifiedResultCount: classified.count
    )
  }

  private static func groups(
    from classified: [ClassifiedResult],
    maximumDocumentCount: Int
  ) -> KnowledgeContextRecommendationPresentationGroups {
    let strong = cards(
      from: classified,
      maximumDocumentCount: maximumDocumentCount,
      strength: .strong
    )
    let strongDocumentIDs = Set(strong.map(\.document.id))
    let possible = cards(
      from: classified.filter { !strongDocumentIDs.contains($0.result.document.id) },
      maximumDocumentCount: maximumDocumentCount,
      strength: .possible
    )
    return KnowledgeContextRecommendationPresentationGroups(strong: strong, possible: possible)
  }

  private static func cards(
    from classified: [ClassifiedResult],
    maximumDocumentCount: Int,
    strength: Strength
  ) -> [KnowledgeContextRecommendationPresentation] {
    guard maximumDocumentCount > 0 else { return [] }
    var grouped = [UUID: [ClassifiedResult]]()
    var documentOrder = [UUID]()
    for item in classified where item.classification.strength == strength {
      if grouped[item.result.document.id] == nil {
        documentOrder.append(item.result.document.id)
      }
      grouped[item.result.document.id, default: []].append(item)
    }
    return documentOrder.prefix(maximumDocumentCount).compactMap { documentID in
      guard
        let groupedResults = grouped[documentID],
        let primary = groupedResults.first
      else {
        return nil
      }
      return KnowledgeContextRecommendationPresentation(
        document: primary.result.document,
        primaryResult: primary.result,
        additionalResults: groupedResults.dropFirst().map(\.result),
        reason: primary.classification.reason
      )
    }
  }

  enum Strength: Equatable, Sendable {
    case strong
    case possible
  }

  private struct ClassifiedResult: Sendable {
    let result: KnowledgeSearchResult
    let classification: (strength: Strength, reason: String)
  }

  private static func classifiedResults(
    from results: [KnowledgeSearchResult],
    queryTerms: [String],
    excludingDocumentIDs: Set<UUID>
  ) -> [ClassifiedResult] {
    var classified = [ClassifiedResult]()
    classified.reserveCapacity(results.count)
    for result in results where !excludingDocumentIDs.contains(result.document.id) {
      if Task.isCancelled { return [] }
      classified.append(
        ClassifiedResult(
          result: result,
          classification: classification(for: result, queryTerms: queryTerms)
        )
      )
    }
    return classified
  }

  /// Fusion scores combine rank contributions from different retrieval paths,
  /// so they cannot be read as a calibrated relevance confidence. A strong
  /// card therefore requires a concrete topic term from the current query to
  /// appear in the displayed title, heading, locator, or chunk. Results with
  /// only a retrieval flag, a generic short token, or semantic proximity stay
  /// folded under "可能相关" rather than being presented as a recommendation.
  static func classification(
    for result: KnowledgeSearchResult,
    query: String
  ) -> (strength: Strength, reason: String) {
    let candidates = specificQueryTerms(in: query)
    return classification(for: result, queryTerms: candidates)
  }

  private static func classification(
    for result: KnowledgeSearchResult,
    queryTerms: [String]
  ) -> (strength: Strength, reason: String) {
    guard !queryTerms.isEmpty else {
      return possibleClassification(for: result)
    }
    let titleTerms = matchedTerms(in: result.document.title, candidates: queryTerms)
    let bodyTerms = matchedTerms(
      in: [result.chunk.headingPath, result.chunk.locator, result.chunk.content]
        .compactMap { $0 }
        .joined(separator: "\n"),
      candidates: queryTerms
    )
    if !titleTerms.isEmpty || !bodyTerms.isEmpty {
      let terms = displayTerms(titleTerms + bodyTerms)
      if !titleTerms.isEmpty, !bodyTerms.isEmpty {
        return (.strong, String(localized: "标题和正文命中：\(terms)"))
      }
      if !titleTerms.isEmpty {
        return (.strong, String(localized: "标题命中：\(terms)"))
      }
      return (.strong, String(localized: "正文命中：\(terms)"))
    }
    return possibleClassification(for: result)
  }

  private static func possibleClassification(
    for result: KnowledgeSearchResult
  ) -> (strength: Strength, reason: String) {
    if result.signals.contains(.semantic) {
      return (.possible, String(localized: "仅有本机语义或泛词检索信号，未发现可展示的具体主题词"))
    }
    return (.possible, String(localized: "未发现可展示的具体主题词"))
  }

  private static func specificQueryTerms(in query: String) -> [String] {
    var terms = [String]()
    var seen = Set<String>()
    for line in query.components(separatedBy: .newlines) {
      let value = queryValue(in: line)
      let tokens = tokenizedTerms(in: value)
      for term in tokens + chineseTopicPhrases(from: tokens) {
        guard isSpecific(term) else { continue }
        let key = normalized(term)
        guard seen.insert(key).inserted else { continue }
        terms.append(term)
      }
    }
    return terms.sorted { $0.count > $1.count }
  }

  /// The query builder labels each field (for example, "标题：" and "当前段落：").
  /// Strip only that label so field metadata never becomes a recommendation term.
  private static func queryValue(in line: String) -> String {
    for label in queryFieldLabels {
      for separator in ["：", ":"] {
        let prefix = label + separator
        if line.hasPrefix(prefix) {
          return String(line.dropFirst(prefix.count))
        }
      }
    }
    return line
  }

  /// NLTokenizer supplies the same word boundaries for Chinese and English
  /// that the system uses elsewhere in local text processing.
  private static func tokenizedTerms(in text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var terms = [String]()
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let term = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
      if !term.isEmpty {
        terms.append(term)
      }
      return true
    }
    return terms
  }

  /// Only join adjacent meaningful Chinese tokens. This lets "资料库" and
  /// "索引" form the topic "资料库索引", but generic framing such as
  /// "如何使用" breaks the sequence instead of becoming a strong-match term.
  private static func chineseTopicPhrases(from tokens: [String]) -> [String] {
    var phrases = [String]()
    var currentTopicTokens = [String]()
    for token in tokens {
      guard containsHan(token), isSpecific(token) else {
        currentTopicTokens = []
        continue
      }
      currentTopicTokens.append(token)
      if currentTopicTokens.count > 3 {
        currentTopicTokens.removeFirst()
      }
      if currentTopicTokens.count >= 2 {
        phrases.append(currentTopicTokens.joined())
      }
    }
    return phrases
  }

  private static func containsHan(_ term: String) -> Bool {
    term.unicodeScalars.contains(where: isHanScalar)
  }

  private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
    (UInt32(0x4E00)...UInt32(0x9FFF)).contains(scalar.value)
  }

  private static func isSpecific(_ term: String) -> Bool {
    let scalars = term.unicodeScalars
    let containsCJK = containsHan(term)
    let normalizedTerm = normalized(term)
    guard !normalizedTerm.isEmpty else { return false }
    if containsCJK {
      return scalars.count >= 2 && !genericChineseTerms.contains(normalizedTerm)
    }
    return scalars.count >= 3
      && !genericEnglishTerms.contains(normalizedTerm)
      && !codeSyntaxTerms.contains(normalizedTerm)
  }

  private static func normalized(_ term: String) -> String {
    term.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).lowercased()
  }

  private static func matchedTerms(in text: String, candidates: [String]) -> [String] {
    guard !text.isEmpty, !candidates.isEmpty else { return [] }
    let hasWordCandidates = candidates.contains { !containsHan($0) }
    let sourceTokens = hasWordCandidates ? Set(tokenizedTerms(in: text).map(normalized)) : []
    return candidates.filter {
      guard !containsHan($0) else {
        return text.range(
          of: $0,
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: .current
        ) != nil
      }
      let normalizedCandidate = normalized($0)
      return sourceTokens.contains(normalizedCandidate)
    }
  }

  private static func displayTerms(_ terms: [String]) -> String {
    var uniqueTerms = [String]()
    var seen = Set<String>()
    for term in terms {
      let key = normalized(term)
      if seen.insert(key).inserted {
        uniqueTerms.append(term)
      }
    }
    return uniqueTerms.prefix(2)
      .map { "“\($0)”" }
      .joined(separator: "、")
  }

  /// These words describe query scaffolding or an action, rather than a
  /// subject. They must not turn an otherwise semantic-only result into a
  /// strong recommendation.
  private static let genericChineseTerms: Set<String> = [
    "标题", "摘要", "标签", "章节", "正文", "上下文", "当前段落",
    "如何", "什么", "为什么", "可以", "需要", "进行", "处理", "解决", "修复", "维护",
    "使用", "查看", "打开", "关闭", "创建", "更新", "常见", "问题", "内容", "文章", "资料",
    "文档", "代码", "示例", "指南", "教程", "方法", "步骤", "说明", "介绍", "相关", "本地",
    "系统", "功能", "设置", "默认", "全部", "部分", "这个", "那个", "关于", "通过", "为了",
    "常见问题", "如何使用", "使用方法", "更新说明", "操作步骤", "相关资料", "本地资料", "资料内容",
    "文章内容", "代码示例", "系统设置", "默认设置", "如何修复",
  ]

  private static let genericEnglishTerms: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "into", "is",
    "it", "of", "on", "or", "that", "the", "this", "to", "with", "using", "guide", "tutorial",
    "introduction", "overview", "update", "system", "article", "content", "document", "file", "data",
    "code", "application", "window", "view", "model", "service", "manager", "controller",
  ]

  /// A source that shares only Swift grammar with the query is still useful as
  /// a semantic candidate, but it is not evidence of a shared writing topic.
  private static let codeSyntaxTerms: Set<String> = [
    "import", "foundation", "swift", "struct", "class", "func", "var", "let", "public", "private",
    "internal", "protocol", "extension", "enum", "async", "await", "return", "throw", "throws", "try",
    "self", "nil", "true", "false", "string", "uuid", "array", "int", "bool", "some", "body",
  ]

  private static let queryFieldLabels: [String] = [
    "标题", "摘要", "标签", "章节", "当前段落", "正文上下文",
  ]
}
