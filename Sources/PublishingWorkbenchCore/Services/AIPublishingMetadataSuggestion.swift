import Foundation

public enum AIPublishingMetadataField: String, CaseIterable, Codable, Identifiable, Sendable {
  case title
  case slug
  case summary
  case tags

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .title:
      return CoreL10n.text("标题")
    case .slug:
      return CoreL10n.text("Slug")
    case .summary:
      return CoreL10n.text("摘要")
    case .tags:
      return CoreL10n.text("Tags")
    }
  }
}

public struct AIPublishingMetadataSuggestion: Hashable, Sendable {
  public var titles: [String]
  public var slugs: [String]
  public var summary: String?
  public var tags: [String]
  public var rawContent: String

  public init(
    titles: [String] = [],
    slugs: [String] = [],
    summary: String? = nil,
    tags: [String] = [],
    rawContent: String = ""
  ) {
    self.titles = titles
    self.slugs = slugs
    self.summary = summary
    self.tags = tags
    self.rawContent = rawContent
  }

  public var hasSuggestions: Bool {
    !titles.isEmpty || !slugs.isEmpty || summary != nil || !tags.isEmpty
  }
}

public enum AIPublishingMetadataSuggestionParser {
  private enum Section {
    case title
    case slug
    case summary
    case tags
  }

  public static func parse(_ text: String) -> AIPublishingMetadataSuggestion {
    var sections: [Section: [String]] = [:]
    var currentSection: Section?

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("```") else {
        continue
      }

      if let header = sectionHeader(line) {
        currentSection = header.section
        if let value = header.value?.nilIfEmpty {
          sections[header.section, default: []].append(value)
        }
        continue
      }

      if let currentSection {
        sections[currentSection, default: []].append(line)
      }
    }

    guard !sections.isEmpty else {
      return AIPublishingMetadataSuggestion(rawContent: text)
    }

    let titles = parseTitleCandidates(sections[.title, default: []].joined(separator: "\n"))
    let slugs = parseSlugCandidates(sections[.slug, default: []].joined(separator: "\n"))
    let summary = parseSummaryCandidate(sections[.summary, default: []].joined(separator: "\n"))
    let tags = parseTagCandidates(sections[.tags, default: []].joined(separator: "\n"))

    return AIPublishingMetadataSuggestion(
      titles: titles,
      slugs: slugs,
      summary: summary,
      tags: tags,
      rawContent: text
    )
  }

  private static func sectionHeader(_ line: String) -> (section: Section, value: String?)? {
    let normalized = line
      .replacingOccurrences(
        of: #"^\s*(?:[-*]\s+|\d+[\).）、]\s*|#{1,6}\s*)"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let separators = [":", "：", "-", "—"]
    for separator in separators {
      if let range = normalized.range(of: separator) {
        let key = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let section = section(for: key) {
          return (section, value)
        }
      }
    }

    if let section = section(for: normalized) {
      return (section, nil)
    }
    return nil
  }

  private static func section(for key: String) -> Section? {
    let normalized = key
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")

    switch normalized {
    case "title", "titles", "标题", "标题候选", "候选标题":
      return .title
    case "slug", "slugs", "路径", "路径候选", "候选slug":
      return .slug
    case "summary", "description", "摘要", "描述", "summarydescription":
      return .summary
    case "tag", "tags", "标签", "tag候选", "tags候选":
      return .tags
    default:
      if normalized.hasPrefix("title") || normalized.hasPrefix("titles")
        || normalized.hasPrefix("标题") || normalized.hasPrefix("候选标题") {
        return .title
      }
      if normalized.hasPrefix("slug") || normalized.hasPrefix("slugs")
        || normalized.hasPrefix("路径") || normalized.hasPrefix("候选slug") {
        return .slug
      }
      if normalized.hasPrefix("summary") || normalized.hasPrefix("description")
        || normalized.hasPrefix("摘要") || normalized.hasPrefix("描述") {
        return .summary
      }
      if normalized.hasPrefix("tag") || normalized.hasPrefix("tags")
        || normalized.hasPrefix("标签") {
        return .tags
      }
      return nil
    }
  }

  public static func parseTitleCandidates(_ text: String) -> [String] {
    var seen: Set<String> = []
    return text
      .components(separatedBy: .newlines)
      .compactMap { rawLine in
        let title = cleanedListValue(rawLine)
        guard (4...90).contains(title.count) else { return nil }
        let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seen.insert(key).inserted else { return nil }
        return title
      }
  }

  public static func parseSlugCandidates(_ text: String) -> [String] {
    var seen: Set<String> = []
    return text
      .components(separatedBy: .newlines)
      .compactMap { rawLine in
        let slug = SlugService.slug(from: cleanedListValue(rawLine)
          .replacingOccurrences(of: ".md", with: "")
          .replacingOccurrences(of: ".markdown", with: ""))
        guard (3...90).contains(slug.count) else { return nil }
        guard seen.insert(slug).inserted else { return nil }
        return slug
      }
  }

  public static func parseSummaryCandidate(_ text: String) -> String? {
    let summary = text
      .components(separatedBy: .newlines)
      .map(cleanedListValue)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard (8...320).contains(summary.count) else {
      return nil
    }
    return summary
  }

  public static func parseTagCandidates(_ text: String) -> [String] {
    var seen: Set<String> = []
    return text
      .components(separatedBy: CharacterSet(charactersIn: "\n,，、;；"))
      .compactMap { rawTag in
        let tag = cleanedListValue(rawTag)
          .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...32).contains(tag.count) else { return nil }
        let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seen.insert(key).inserted else { return nil }
        return tag
      }
  }

  private static func cleanedListValue(_ rawLine: String) -> String {
    var value = rawLine
      .replacingOccurrences(
        of: #"^\s*(?:[-*]\s+|\d+[\).）、]\s*|#+\s*)"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'“”‘’《》「」`"))

    while let last = value.last,
      [".", "。", "，", ",", ";", "；", "\"", "'", "“", "”", "‘", "’", "》", "」", "`"].contains(last)
    {
      value.removeLast()
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return value
  }
}

public enum AIPublishingMetadataActionSuggestionFactory {
  public static func suggestion(
    from result: AIPublishingActionResult
  ) -> AIPublishingMetadataSuggestion? {
    let suggestion: AIPublishingMetadataSuggestion
    switch result.kind {
    case .suggestTitles:
      suggestion = AIPublishingMetadataSuggestion(
        titles: AIPublishingMetadataSuggestionParser.parseTitleCandidates(result.content),
        rawContent: result.content
      )
    case .suggestSlug:
      suggestion = AIPublishingMetadataSuggestion(
        slugs: AIPublishingMetadataSuggestionParser.parseSlugCandidates(result.content),
        rawContent: result.content
      )
    case .suggestSummary:
      suggestion = AIPublishingMetadataSuggestion(
        summary: AIPublishingMetadataSuggestionParser.parseSummaryCandidate(result.content),
        rawContent: result.content
      )
    case .suggestTags:
      suggestion = AIPublishingMetadataSuggestion(
        tags: AIPublishingMetadataSuggestionParser.parseTagCandidates(result.content),
        rawContent: result.content
      )
    case .titleSummaryTags, .draftFrontMatterPack, .draftBilingualMetadata:
      suggestion = AIPublishingMetadataSuggestionParser.parse(result.content)
    default:
      return nil
    }

    return suggestion.hasSuggestions ? suggestion : nil
  }
}

public extension AIPublishingActionKind {
  var producesMetadataSuggestion: Bool {
    switch self {
    case .suggestTitles, .suggestSlug, .suggestSummary, .suggestTags,
      .titleSummaryTags, .draftFrontMatterPack, .draftBilingualMetadata:
      return true
    default:
      return false
    }
  }
}
