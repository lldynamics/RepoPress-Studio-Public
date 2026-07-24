import Foundation

public struct KnowledgeSearchHitPresentation: Hashable, Sendable {
  public var snippet: String
  public var highlightTerms: [String]
  public var reasons: [KnowledgeRetrievalSignal]
  public var locationLabel: String?
  public var paragraphAnchor: String

  public init(
    snippet: String,
    highlightTerms: [String],
    reasons: [KnowledgeRetrievalSignal],
    locationLabel: String?,
    paragraphAnchor: String
  ) {
    self.snippet = snippet
    self.highlightTerms = highlightTerms
    self.reasons = reasons
    self.locationLabel = locationLabel
    self.paragraphAnchor = paragraphAnchor
  }
}

public struct KnowledgeSearchPresentationService: Sendable {
  public init() {}

  public func presentation(
    for result: KnowledgeSearchResult,
    query: String,
    maximumSnippetCharacters: Int = 240
  ) -> KnowledgeSearchHitPresentation {
    let terms = searchTerms(in: query)
    let paragraphs = result.chunk.content
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let anchor = paragraphs.first(where: { containsAnyTerm($0, terms: terms) })
      ?? paragraphs.first
      ?? result.chunk.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return KnowledgeSearchHitPresentation(
      snippet: contextualSnippet(
        anchor,
        terms: terms,
        maximumCharacters: max(80, maximumSnippetCharacters)
      ),
      highlightTerms: terms,
      reasons: orderedSignals(result.signals),
      locationLabel: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
      paragraphAnchor: anchor
    )
  }

  public func lexicalSignals(
    for result: KnowledgeSearchResult,
    query: String
  ) -> Set<KnowledgeRetrievalSignal> {
    let terms = searchTerms(in: query)
    guard !terms.isEmpty else { return [.fullText] }
    var signals = Set<KnowledgeRetrievalSignal>()
    if containsAnyTerm(result.document.title, terms: terms) {
      signals.insert(.title)
    }
    let searchableBody = [result.chunk.headingPath, result.chunk.locator, result.chunk.content]
      .compactMap { $0 }
      .joined(separator: "\n")
    if containsAnyTerm(searchableBody, terms: terms) {
      signals.insert(.fullText)
    }
    // FTS also indexes authors. Keep those lexical hits explainable even when
    // the visible title and chunk do not contain the exact token.
    if signals.isEmpty {
      signals.insert(.fullText)
    }
    return signals
  }

  public func targetBlockID(
    in blocks: [KnowledgeDocumentBlock],
    for result: KnowledgeSearchResult,
    query: String
  ) -> Int? {
    guard !blocks.isEmpty else { return nil }
    let hit = presentation(for: result, query: query)
    let anchor = normalizedForComparison(hit.paragraphAnchor)
    let chunk = normalizedForComparison(result.chunk.content)
    let headingPath = normalizedForComparison(result.chunk.headingPath ?? "")
    let locator = normalizedForComparison(result.chunk.locator ?? "")
    let terms = hit.highlightTerms.map(normalizedForComparison).filter { !$0.isEmpty }
    var activeHeading = ""
    var best: (id: Int, score: Int)?

    for block in blocks {
      if case .heading = block.kind {
        activeHeading = normalizedForComparison(block.text)
      }
      let text = normalizedForComparison(block.text)
      guard !text.isEmpty else { continue }
      var score = 0

      if !anchor.isEmpty, text == anchor {
        score += 400
      } else if anchor.count >= 16, text.contains(anchor) {
        score += 360
      } else if text.count >= 16, anchor.contains(text) {
        score += 300
      } else if text.count >= 24, chunk.contains(text) {
        score += 180
      }

      if !terms.isEmpty, terms.contains(where: text.contains) {
        score += 45
      }
      if !headingPath.isEmpty,
         !activeHeading.isEmpty,
         headingPath.contains(activeHeading) {
        score += 35
      }
      if case .locator = block.kind, !locator.isEmpty, text == locator {
        score += 120
      }
      if case .heading = block.kind, !headingPath.isEmpty, headingPath.contains(text) {
        score += 25
      }

      if score > (best?.score ?? 0) {
        best = (block.id, score)
      }
    }

    return best?.id ?? blocks.first?.id
  }

  private func searchTerms(in query: String) -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let tokens = trimmed
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
    var output: [String] = []
    var normalized = Set<String>()
    for candidate in [trimmed] + tokens {
      let key = candidate.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      guard normalized.insert(key).inserted else { continue }
      output.append(candidate)
    }
    return output.sorted { $0.count > $1.count }
  }

  private func orderedSignals(
    _ signals: Set<KnowledgeRetrievalSignal>
  ) -> [KnowledgeRetrievalSignal] {
    [.title, .fullText, .semantic].filter(signals.contains)
  }

  private func containsAnyTerm(_ text: String, terms: [String]) -> Bool {
    terms.contains { term in
      text.range(
        of: term,
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      ) != nil
    }
  }

  private func contextualSnippet(
    _ text: String,
    terms: [String],
    maximumCharacters: Int
  ) -> String {
    let compact = text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > maximumCharacters else { return compact }

    let match = terms.compactMap { term in
      compact.range(
        of: term,
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
    }.min { lhs, rhs in
      compact.distance(from: compact.startIndex, to: lhs.lowerBound)
        < compact.distance(from: compact.startIndex, to: rhs.lowerBound)
    }
    let matchOffset = match.map {
      compact.distance(from: compact.startIndex, to: $0.lowerBound)
    } ?? 0
    let startOffset = min(
      max(0, matchOffset - maximumCharacters / 3),
      max(0, compact.count - maximumCharacters)
    )
    let start = compact.index(compact.startIndex, offsetBy: startOffset)
    let end = compact.index(start, offsetBy: maximumCharacters, limitedBy: compact.endIndex)
      ?? compact.endIndex
    let prefix = start > compact.startIndex ? "…" : ""
    let suffix = end < compact.endIndex ? "…" : ""
    return prefix + compact[start..<end] + suffix
  }

  private func normalizedForComparison(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}
