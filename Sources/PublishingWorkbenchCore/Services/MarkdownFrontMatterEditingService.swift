import Foundation
import PublishingDomainContracts
import RepoPressCore

public enum MarkdownFrontMatterEditingIssue: Error, Equatable, Sendable {
  case invalidDelimiter
  case concurrentBodyChange
  case malformedLine(Int)
  case missingDate
  case invalidDate
  case invalidDraftFlag
  case invalidVisibility
}

public struct MarkdownFrontMatterEditingResult: Equatable, Sendable {
  public var draft: ArticleDraft
  public var issue: MarkdownFrontMatterEditingIssue?

  public init(draft: ArticleDraft, issue: MarkdownFrontMatterEditingIssue? = nil) {
    self.draft = draft
    self.issue = issue
  }

  public var isValid: Bool {
    issue == nil
  }
}

public struct MarkdownFrontMatterDocumentParts: Equatable, Sendable {
  public var frontMatter: String
  public var bodyMarkdown: String
  public var bodyUTF16Offset: Int

  public init(frontMatter: String, bodyMarkdown: String, bodyUTF16Offset: Int) {
    self.frontMatter = frontMatter
    self.bodyMarkdown = bodyMarkdown
    self.bodyUTF16Offset = bodyUTF16Offset
  }
}

/// Presents the editable article metadata as YAML or TOML Front Matter and
/// applies valid source edits back to the structured draft model.
public struct MarkdownFrontMatterEditingService: Sendable {
  public init() {}

  public func render(draft: ArticleDraft, profile: SiteProfile) -> String {
    if draft.importedFrontMatter != nil {
      return FrontMatterRenderer().render(draft: draft, profile: profile)
    }
    switch profile.frontMatterStyle {
    case .yaml:
      return renderYAML(draft: draft, profile: profile)
    case .toml:
      return renderTOML(draft: draft, profile: profile)
    }
  }

  public func renderDocument(
    draft: ArticleDraft,
    profile: SiteProfile,
    bodyMarkdown: String? = nil
  ) -> String {
    composeDocument(
      frontMatter: render(draft: draft, profile: profile),
      bodyMarkdown: bodyMarkdown ?? draft.bodyMarkdown
    )
  }

  public func composeDocument(frontMatter: String, bodyMarkdown: String) -> String {
    frontMatter.trimmingCharacters(in: .newlines) + "\n\n" + bodyMarkdown
  }

  public func splitDocument(
    _ source: String,
    profile: SiteProfile
  ) -> MarkdownFrontMatterDocumentParts? {
    let expectedDelimiter: FrontMatterDelimiter =
      profile.frontMatterStyle == .yaml
      ? .yaml
      : .toml
    guard
      let document = DelimitedFrontMatterParser().split(
        source,
        expectedDelimiter: expectedDelimiter
      )
    else { return nil }
    return MarkdownFrontMatterDocumentParts(
      frontMatter: document.frontMatter,
      bodyMarkdown: document.body,
      bodyUTF16Offset: document.bodyUTF16Offset
    )
  }

  public func applying(
    _ source: String,
    to draft: ArticleDraft,
    profile: SiteProfile
  ) -> MarkdownFrontMatterEditingResult {
    let parts = ImportedFrontMatter.split(source)
    let expectedSyntax =
      draft.importedFrontMatter?.syntax
      ?? (profile.frontMatterStyle == .toml ? .toml : .yaml)
    guard let envelope = parts.frontMatter, envelope.syntax == expectedSyntax,
      parts.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return MarkdownFrontMatterEditingResult(draft: draft, issue: .invalidDelimiter)
    }
    do { _ = try envelope.replacing([:]) } catch {
      let legacyParse = parse(
        source, delimiter: envelope.syntax == .toml ? "+++" : "---",
        separator: envelope.syntax == .toml ? "=" : ":",
        style: envelope.syntax == .toml ? .toml : .yaml)
      if case .failure(let issue) = legacyParse {
        return MarkdownFrontMatterEditingResult(draft: draft, issue: issue)
      }
      return MarkdownFrontMatterEditingResult(draft: draft, issue: .malformedLine(2))
    }
    var values = ArticleFrontMatterPreservation.values(from: envelope, profile: profile)
    if values["draft"] == nil, profile.siteKind == .quartz,
      let publish = values["publish"]?.first.flatMap(parsedBool)
    {
      values["draft"] = [publish ? "false" : "true"]
    }
    if values["draft"] == nil, profile.siteKind == .foam, let status = values["status"]?.first {
      values["draft"] = [status.lowercased() == "draft" ? "true" : "false"]
    }
    if draft.importedFrontMatter != nil, values["date"] == nil {
      values["date"] =
        values["published"] ?? values["publishdate"] ?? values["created"]
        ?? [formattedDate(draft.date, profile: profile)]
    }

    guard let dateText = values["date"]?.first?.trimmedForPublishing.nilIfEmpty else {
      return MarkdownFrontMatterEditingResult(draft: draft, issue: .missingDate)
    }

    var updated = draft
    if dateText != formattedDate(draft.date, profile: profile) {
      guard let parsedDate = parsedDate(dateText, profile: profile) else {
        return MarkdownFrontMatterEditingResult(draft: draft, issue: .invalidDate)
      }
      updated.date = parsedDate
    }

    if let draftText = values["draft"]?.first {
      guard let draftFlag = parsedBool(draftText) else {
        return MarkdownFrontMatterEditingResult(draft: draft, issue: .invalidDraftFlag)
      }
      updated.draft = draftFlag
    } else {
      updated.draft = draft.importedFrontMatter == nil ? false : draft.draft
    }

    let visibilityText: String
    if let explicitVisibility = values["visibility"]?.first {
      visibilityText = explicitVisibility
    } else if let privateText = values["private"]?.first {
      guard let isPrivate = parsedBool(privateText) else {
        return MarkdownFrontMatterEditingResult(draft: draft, issue: .invalidVisibility)
      }
      visibilityText =
        isPrivate
        ? ArticleVisibility.private.rawValue
        : ArticleVisibility.public.rawValue
    } else {
      visibilityText =
        draft.importedFrontMatter == nil
        ? ArticleVisibility.public.rawValue : draft.visibility.rawValue
    }
    guard
      let visibility = ArticleVisibility(rawValue: visibilityText.trimmedForPublishing.lowercased())
    else {
      return MarkdownFrontMatterEditingResult(draft: draft, issue: .invalidVisibility)
    }

    updated.title = values["title"]?.first ?? (draft.importedFrontMatter == nil ? "" : draft.title)
    updated.slug = values["slug"]?.first ?? (draft.importedFrontMatter == nil ? "" : draft.slug)
    updated.summary =
      values["description"]?.first
      ?? values["summary"]?.first
      ?? values["excerpt"]?.first
      ?? values["socialdescription"]?.first
      ?? ""
    updated.authors = values["authors"] ?? values["author"] ?? []
    updated.aliases = values["aliases"] ?? values["alias"] ?? []
    updated.permalink = values["permalink"]?.first?.trimmedForPublishing.nilIfEmpty
    if profile.siteKind == .hugo {
      updated.translationKey = values["translationkey"]?.first?.trimmedForPublishing.nilIfEmpty
    }
    updated.tags = values["tags"] ?? []
    updated.categories = values["categories"] ?? []
    updated.visibility = visibility
    if !ArticleFrontMatterPreservation.requiresLegacyRecovery(draft: draft) {
      updated.importedFrontMatter = ArticleFrontMatterPreservation.capturing(
        envelope, draft: updated, profile: profile)
    }
    // Editing a regenerated legacy preview cannot establish the missing
    // original-file baseline. Only reimport/conflict recovery can do that.

    return MarkdownFrontMatterEditingResult(draft: updated)
  }

  private enum ParsingStyle: Equatable {
    case yaml
    case toml
  }

  private func parse(
    _ source: String,
    delimiter: String,
    separator: Character,
    style: ParsingStyle
  ) -> Result<[String: [String]], MarkdownFrontMatterEditingIssue> {
    var lines =
      source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")

    while lines.first?.trimmedForPublishing.isEmpty == true {
      lines.removeFirst()
    }
    while lines.last?.trimmedForPublishing.isEmpty == true {
      lines.removeLast()
    }

    guard lines.count >= 2,
      lines.first?.trimmedForPublishing == delimiter,
      lines.last?.trimmedForPublishing == delimiter
    else {
      return .failure(.invalidDelimiter)
    }

    var values: [String: [String]] = [:]
    var pendingYAMLListKey: String?

    for (offset, rawLine) in lines.dropFirst().dropLast().enumerated() {
      let lineNumber = offset + 2
      let trimmed = rawLine.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

      if style == .toml, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
        pendingYAMLListKey = nil
        continue
      }

      if style == .yaml, trimmed.hasPrefix("- ") {
        guard let pendingYAMLListKey else {
          return .failure(.malformedLine(lineNumber))
        }
        let item = cleanScalar(String(trimmed.dropFirst(2)))
        if !item.isEmpty {
          values[pendingYAMLListKey, default: []].append(item)
        }
        continue
      }

      guard let separatorIndex = trimmed.firstIndex(of: separator) else {
        return .failure(.malformedLine(lineNumber))
      }

      let key = String(trimmed[..<separatorIndex]).trimmedForPublishing.lowercased()
      guard !key.isEmpty else {
        return .failure(.malformedLine(lineNumber))
      }

      let rawValue = String(trimmed[trimmed.index(after: separatorIndex)...]).trimmedForPublishing
      if style == .yaml, rawValue.isEmpty {
        values[key] = []
        pendingYAMLListKey = key
      } else {
        values[key] = parseScalarOrArray(rawValue)
        pendingYAMLListKey = nil
      }
    }

    return .success(values)
  }

  private func renderYAML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines = [
      "---",
      "title: \(quotedString(draft.title))",
      "date: \(quotedString(formattedDate(draft.date, profile: profile)))",
      "slug: \(quotedString(draft.slug))",
      "description: \(quotedString(draft.summary))",
      "authors: \(array(draft.authors))",
    ]
    if !draft.aliases.isEmpty {
      lines.append("aliases: \(array(draft.aliases))")
    }
    if let permalink = draft.permalink?.trimmedForPublishing.nilIfEmpty {
      lines.append("permalink: \(quotedString(permalink))")
    }
    if profile.siteKind == .hugo, let key = draft.translationKey?.trimmedForPublishing.nilIfEmpty {
      lines.append("translationKey: \(quotedString(key))")
    }
    if profile.siteKind == .zola {
      lines.append(contentsOf: [
        "taxonomies:", "  tags: \(array(draft.tags))", "  categories: \(array(draft.categories))",
      ])
    } else {
      lines.append(contentsOf: [
        "tags: \(array(draft.tags))", "categories: \(array(draft.categories))",
      ])
    }
    lines.append(contentsOf: [
      "draft: \(draft.draft ? "true" : "false")",
      "visibility: \(quotedString(draft.visibility.rawValue))",
      "---",
    ])
    return lines.joined(separator: "\n")
  }

  private func renderTOML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines = [
      "+++",
      "title = \(quotedString(draft.title))",
      "date = \(quotedString(formattedDate(draft.date, profile: profile)))",
      "slug = \(quotedString(draft.slug))",
      "description = \(quotedString(draft.summary))",
      "authors = \(array(draft.authors))",
    ]
    if !draft.aliases.isEmpty {
      lines.append("aliases = \(array(draft.aliases))")
    }
    if let permalink = draft.permalink?.trimmedForPublishing.nilIfEmpty {
      lines.append("permalink = \(quotedString(permalink))")
    }
    if profile.siteKind == .hugo, let key = draft.translationKey?.trimmedForPublishing.nilIfEmpty {
      lines.append("translationKey = \(quotedString(key))")
    }
    if profile.siteKind == .zola {
      lines.append(
        "taxonomies = { tags = \(array(draft.tags)), categories = \(array(draft.categories)) }")
    } else {
      lines.append(contentsOf: [
        "tags = \(array(draft.tags))", "categories = \(array(draft.categories))",
      ])
    }
    lines.append(contentsOf: [
      "draft = \(draft.draft ? "true" : "false")",
      "visibility = \(quotedString(draft.visibility.rawValue))",
      "+++",
    ])
    return lines.joined(separator: "\n")
  }

  private func formattedDate(_ date: Date, profile: SiteProfile) -> String {
    FrontMatterRenderer.formattedDate(
      date, format: profile.dateFormat.trimmedForPublishing.nilIfEmpty ?? "yyyy-MM-dd")
  }

  private func parsedDate(_ value: String, profile: SiteProfile) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = profile.dateFormat.trimmedForPublishing.nilIfEmpty ?? "yyyy-MM-dd"
    if let date = formatter.date(from: value) {
      return date
    }
    return ISO8601DateFormatter().date(from: value)
  }

  private func parsedBool(_ value: String) -> Bool? {
    switch value.trimmedForPublishing.lowercased() {
    case "true", "yes", "1":
      return true
    case "false", "no", "0":
      return false
    default:
      return nil
    }
  }

  private func array(_ values: [String]) -> String {
    "[" + values.map(quotedString).joined(separator: ", ") + "]"
  }

  private func quotedString(_ value: String) -> String {
    "\""
      + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n") + "\""
  }

  private func parseScalarOrArray(_ rawValue: String) -> [String] {
    let value = rawValue.trimmedForPublishing
    guard value.hasPrefix("["), value.hasSuffix("]") else {
      let scalar = cleanScalar(value)
      return scalar.isEmpty ? [] : [scalar]
    }

    let inner = String(value.dropFirst().dropLast())
    return splitArray(inner)
      .map(cleanScalar)
      .filter { !$0.isEmpty }
  }

  private func splitArray(_ source: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    var isEscaped = false

    for character in source {
      if isEscaped {
        current.append(character)
        isEscaped = false
        continue
      }
      if character == "\\", quote != nil {
        current.append(character)
        isEscaped = true
        continue
      }
      if character == "\"" || character == "'" {
        if quote == character {
          quote = nil
        } else if quote == nil {
          quote = character
        }
        current.append(character)
        continue
      }
      if character == ",", quote == nil {
        parts.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    parts.append(current)
    return parts
  }

  private func cleanScalar(_ value: String) -> String {
    let trimmed = value.trimmedForPublishing
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
      let data = trimmed.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(String.self, from: data)
    {
      return decoded.trimmedForPublishing
    }
    if trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
      return String(trimmed.dropFirst().dropLast()).trimmedForPublishing
    }
    return trimmed
  }
}
