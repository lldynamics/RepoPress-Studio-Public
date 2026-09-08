import Foundation
import PublishingCoreSupport

/// A citation-aware rendering of an AI response. The response body is kept
/// separate from any missing definition footer so replacing a small selection
/// does not place an entire references section inside that selection.
public struct KnowledgeCitationApplicationPlan: Equatable, Sendable {
  public let renderedContent: String
  public let referencedCitations: [KnowledgeCitation]
  public let missingDefinitions: [String]

  public init(
    renderedContent: String,
    referencedCitations: [KnowledgeCitation],
    missingDefinitions: [String]
  ) {
    self.renderedContent = renderedContent
    self.referencedCitations = referencedCitations
    self.missingDefinitions = missingDefinitions
  }

  /// Adds only definitions that are absent from the destination article.
  /// This keeps a selected replacement focused on prose while retaining a
  /// stable, article-level reference section.
  public func appendingMissingDefinitions(to markdown: String) -> String {
    guard !missingDefinitions.isEmpty else { return markdown }
    let footer = "## 资料来源\n\n" + missingDefinitions.joined(separator: "\n")
    guard !markdown.isEmpty else { return footer }
    let separator: String
    if markdown.hasSuffix("\n\n") {
      separator = ""
    } else if markdown.hasSuffix("\n") {
      separator = "\n"
    } else {
      separator = "\n\n"
    }
    return markdown + separator + footer
  }
}

public enum KnowledgeCitationMarkdownService {
  /// Makes the common citation application plan used by append and selection
  /// replacement entry points. Only response markers found in prose become
  /// article citations or backlinks.
  public static func applicationPlan(
    for markdown: String,
    candidates: [KnowledgeCitation],
    existingMarkdown: String = ""
  ) -> KnowledgeCitationApplicationPlan {
    let content = markdown.trimmedForPublishing
    guard !candidates.isEmpty else {
      return KnowledgeCitationApplicationPlan(
        renderedContent: content,
        referencedCitations: [],
        missingDefinitions: []
      )
    }

    let byResponseMarker = unambiguousMarkers(from: candidates)
    let rewritten = replacingResponseMarkers(in: content, citations: byResponseMarker)
    let referenced = uniqueSources(candidates.compactMap { byResponseMarker[$0.id] })
      .sorted(by: citationOrder)
      .filter { containsOutsideCode(footnoteReference(for: $0), in: rewritten) }
    let combined = [existingMarkdown.trimmedForPublishing, rewritten]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    let definitions =
      referenced
      .filter { !containsDefinition(for: $0, in: combined) }
      .map { footnoteDefinition(for: $0) }
    return KnowledgeCitationApplicationPlan(
      renderedContent: rewritten,
      referencedCitations: referenced,
      missingDefinitions: definitions
    )
  }

  /// Appends definitions for citations already present as footnote references
  /// in a destination article. This is used after a selection edit has placed
  /// its prose at the caret, so reference definitions remain article-level.
  public static func appendingMissingDefinitions(
    to markdown: String,
    citations: [KnowledgeCitation]
  ) -> String {
    let referenced = uniqueSources(citations)
      .sorted(by: citationOrder)
      .filter { containsOutsideCode(footnoteReference(for: $0), in: markdown) }
    let definitions =
      referenced
      .filter { !containsDefinition(for: $0, in: markdown) }
      .map { footnoteDefinition(for: $0) }
    return KnowledgeCitationApplicationPlan(
      renderedContent: "",
      referencedCitations: referenced,
      missingDefinitions: definitions
    )
    .appendingMissingDefinitions(to: markdown)
  }

  /// Converts only citations that the response actually places in prose and
  /// appends missing definitions. `existingMarkdown` is the destination draft,
  /// allowing a later AI response to reuse a source definition already present
  /// in the article.
  public static func appendingCitations(
    to markdown: String,
    citations: [KnowledgeCitation],
    existingMarkdown: String = ""
  ) -> String {
    let plan = applicationPlan(
      for: markdown,
      candidates: citations,
      existingMarkdown: existingMarkdown
    )
    return plan.appendingMissingDefinitions(to: plan.renderedContent)
  }

  /// Returns only sources whose response marker occurs in prose. Callers use
  /// this for article backlinks so an unreferenced retrieval is not recorded
  /// as though it supported the applied text.
  public static func referencedCitations(
    in markdown: String,
    candidates: [KnowledgeCitation]
  ) -> [KnowledgeCitation] {
    let markers = unambiguousMarkers(from: candidates)
    let prose = replacingResponseMarkers(in: markdown, citations: markers)
    return uniqueSources(candidates.compactMap { markers[$0.id] }).sorted(by: citationOrder).filter
    {
      containsOutsideCode(footnoteReference(for: $0), in: prose)
    }
  }

  public static func footnoteReference(
    for citation: KnowledgeCitation,
    fallbackIndex: Int = 1
  ) -> String {
    "[^\(footnoteKey(for: citation, fallbackIndex: fallbackIndex))]"
  }

  public static func footnoteDefinition(
    for citation: KnowledgeCitation,
    fallbackIndex: Int = 1
  ) -> String {
    let key = footnoteKey(for: citation, fallbackIndex: fallbackIndex)
    let authors = citation.authors.joined(separator: "、")
    let location = citation.locator?.trimmedForPublishing.nilIfEmpty
    let metadata = [authors.nilIfEmpty, location].compactMap { $0 }.joined(separator: "，")
    let source = citation.sourceURL.map { "[来源](\($0.absoluteString))" }
    let suffix = [metadata.nilIfEmpty, source].compactMap { $0 }.joined(separator: "；")
    return
      "[^\(key)]: \(citation.title)\(suffix.isEmpty ? "" : "（\(suffix)）")。\(citation.excerpt.trimmedForPublishing)"
  }

  public static func footnoteKey(for citation: KnowledgeCitation, fallbackIndex: Int) -> String {
    let document = stableToken(citation.documentID.uuidString)
    let revision = citation.revisionID.map { stableToken($0.uuidString) }
    let chunk = stableToken(citation.chunkID.uuidString)
    if let revision {
      return "kb-d\(document)-r\(revision)-c\(chunk)"
    }
    // Old persisted conversations have no revision identity. Keep those
    // citations stable without pretending to know their historical revision.
    let legacy = stableToken(citation.id)
    return "kb-d\(document)-legacy-\(legacy.isEmpty ? String(fallbackIndex) : legacy)-c\(chunk)"
  }

  private static func sameSource(_ lhs: KnowledgeCitation, _ rhs: KnowledgeCitation) -> Bool {
    lhs.documentID == rhs.documentID
      && lhs.revisionID == rhs.revisionID
      && lhs.chunkID == rhs.chunkID
      && (lhs.revisionID != nil || lhs.id == rhs.id)
  }

  private static func containsDefinition(for citation: KnowledgeCitation, in markdown: String)
    -> Bool
  {
    containsOutsideCode("[^\(footnoteKey(for: citation, fallbackIndex: 1))]:", in: markdown)
  }

  private static func replacingResponseMarkers(
    in markdown: String,
    citations: [String: KnowledgeCitation]
  ) -> String {
    var fence: MarkdownFence?
    return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
      let line = String(rawLine)
      if let activeFence = fence {
        if activeFence.closes(line) {
          fence = nil
        }
        return line
      }
      if let openingFence = MarkdownFence.opening(line) {
        fence = openingFence
        return line
      }
      return replacingMarkersOutsideInlineCode(in: line, citations: citations)
    }.joined(separator: "\n")
  }

  private static func unambiguousMarkers(
    from citations: [KnowledgeCitation]
  ) -> [String: KnowledgeCitation] {
    let grouped = Dictionary(
      grouping: citations.filter { !$0.id.trimmedForPublishing.isEmpty }, by: \.id)
    return grouped.reduce(into: [:]) { result, entry in
      guard let first = entry.value.first,
        entry.value.dropFirst().allSatisfy({ sameSource(first, $0) })
      else { return }
      result[entry.key] = first
    }
  }

  private static func uniqueSources<S: Sequence>(_ citations: S) -> [KnowledgeCitation]
  where S.Element == KnowledgeCitation {
    citations.reduce(into: [KnowledgeCitation]()) { result, citation in
      guard !result.contains(where: { sameSource($0, citation) }) else { return }
      result.append(citation)
    }
  }

  private static func citationOrder(_ lhs: KnowledgeCitation, _ rhs: KnowledgeCitation) -> Bool {
    footnoteKey(for: lhs, fallbackIndex: 1) < footnoteKey(for: rhs, fallbackIndex: 1)
  }

  private static func containsOutsideCode(_ token: String, in markdown: String) -> Bool {
    var fence: MarkdownFence?
    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if let activeFence = fence {
        if activeFence.closes(line) { fence = nil }
        continue
      }
      if let openingFence = MarkdownFence.opening(line) {
        fence = openingFence
        continue
      }
      if containsOutsideInlineCode(token, in: line) { return true }
    }
    return false
  }

  private static func replacingMarkersOutsideInlineCode(
    in line: String,
    citations: [String: KnowledgeCitation]
  ) -> String {
    let markers =
      citations
      .map { ("[\($0.key)]", $0.value) }
      .sorted { $0.0.count > $1.0.count }
    guard !markers.isEmpty else { return line }

    var result = ""
    var index = line.startIndex
    var inlineFenceLength: Int?
    while index < line.endIndex {
      if line[index] == "`" {
        let end = line[index...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
        let length = line.distance(from: index, to: end)
        result += String(line[index..<end])
        if inlineFenceLength == nil {
          inlineFenceLength = length
        } else if inlineFenceLength == length {
          inlineFenceLength = nil
        }
        index = end
        continue
      }
      if inlineFenceLength == nil,
        let marker = markers.first(where: { line[index...].hasPrefix($0.0) })
      {
        result += footnoteReference(for: marker.1)
        index = line.index(index, offsetBy: marker.0.count)
        continue
      }
      result.append(line[index])
      index = line.index(after: index)
    }
    return result
  }

  private static func containsOutsideInlineCode(_ token: String, in line: String) -> Bool {
    var index = line.startIndex
    var inlineFenceLength: Int?
    while index < line.endIndex {
      if line[index] == "`" {
        let end = line[index...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
        let length = line.distance(from: index, to: end)
        if inlineFenceLength == nil {
          inlineFenceLength = length
        } else if inlineFenceLength == length {
          inlineFenceLength = nil
        }
        index = end
        continue
      }
      if inlineFenceLength == nil, line[index...].hasPrefix(token) {
        return true
      }
      index = line.index(after: index)
    }
    return false
  }

  private struct MarkdownFence {
    let character: Character
    let length: Int

    static func opening(_ line: String) -> MarkdownFence? {
      guard let trimmed = fenceContent(in: line) else { return nil }
      guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
      let length = trimmed.prefix(while: { $0 == character }).count
      guard length >= 3 else { return nil }
      return MarkdownFence(character: character, length: length)
    }

    func closes(_ line: String) -> Bool {
      guard let trimmed = Self.fenceContent(in: line) else { return false }
      let runLength = trimmed.prefix(while: { $0 == character }).count
      guard runLength >= length else { return false }
      return trimmed.dropFirst(runLength).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func fenceContent(in line: String) -> Substring? {
      let leadingSpaces = line.prefix(while: { $0 == " " })
      guard leadingSpaces.count <= 3 else { return nil }
      return line.dropFirst(leadingSpaces.count)
    }
  }

  private static func stableToken(_ value: String) -> String {
    String(
      value.lowercased().map { character in
        character.isLetter || character.isNumber ? character : "-"
      }
    ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}
