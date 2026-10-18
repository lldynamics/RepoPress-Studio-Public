import Foundation

public struct FrontMatterRenderer: Sendable {
  public init() {}

  public func render(draft: ArticleDraft, profile: SiteProfile) -> String {
    if let source = draft.importedFrontMatter {
      // Unsafe edits remain visible as blockers. Never fall back to a
      // destructive canonical rewrite of an imported envelope.
      do {
        return try ArticleFrontMatterPreservation.rendered(draft: draft, profile: profile)
          ?? source.rawBlock
      } catch {
        // Preservation preflight blocks writes; previews retain the source.
        return source.rawBlock
      }
    }
    switch profile.frontMatterStyle {
    case .yaml:
      return renderYAML(draft: draft, profile: profile)
    case .toml:
      return renderTOML(draft: draft, profile: profile)
    }
  }

  public func renderDocument(draft: ArticleDraft, profile: SiteProfile) -> String {
    let body = draft.bodyMarkdown.trimmingCharacters(in: .newlines)
    let header = render(draft: draft, profile: profile)
    return (header.isEmpty ? "" : header + "\n\n") + body + "\n"
  }

  private func renderYAML(draft: ArticleDraft, profile: SiteProfile) -> String {
    if profile.siteKind == .quartz {
      return renderQuartzYAML(draft: draft, profile: profile)
    }
    if profile.siteKind == .docusaurus || profile.siteKind == .mkDocs
      || (profile.siteKind == .astro && profile.contentRoot == "src/content/docs")
    {
      return renderDocumentationYAML(draft: draft, profile: profile)
    }
    var lines: [String] = ["---"]
    lines.append("title: \(yamlString(draft.title))")
    lines.append(
      "\(dateFieldName(for: profile.siteKind)): \(yamlString(formattedDate(draft.date, profile: profile)))"
    )
    lines.append("slug: \(yamlString(draft.slug))")
    if profile.siteKind == .hugo, let key = draft.translationKey?.trimmedForPublishing.nilIfEmpty {
      lines.append("translationKey: \(yamlString(key))")
    }

    if !draft.summary.trimmedForPublishing.isEmpty {
      lines.append("description: \(yamlString(draft.summary))")
    }

    let authors = effectiveAuthors(draft: draft, profile: profile)
    if !authors.isEmpty {
      lines.append("authors: \(yamlArray(authors))")
    }

    if profile.siteKind == .zola, !draft.tags.isEmpty || !draft.categories.isEmpty {
      lines.append("taxonomies:")
      if !draft.tags.isEmpty { lines.append("  tags: \(yamlArray(draft.tags))") }
      if !draft.categories.isEmpty { lines.append("  categories: \(yamlArray(draft.categories))") }
    } else if !draft.tags.isEmpty {
      lines.append("tags: \(yamlArray(draft.tags))")
    }

    if profile.siteKind != .zola, !draft.categories.isEmpty {
      lines.append("categories: \(yamlArray(draft.categories))")
    }

    if !draft.aliases.isEmpty {
      lines.append("aliases: \(yamlArray(draft.aliases))")
    }

    if let permalink = draft.permalink?.nilIfEmpty {
      lines.append("permalink: \(yamlString(permalink))")
    }

    if profile.includeDraftFlagInFrontMatter {
      if profile.siteKind == .foam {
        lines.append("status: \(yamlString(draft.draft ? "draft" : "published"))")
      } else {
        lines.append("draft: \(draft.draft ? "true" : "false")")
      }
    }

    if let coverPath = frontMatterCoverPath(draft: draft, profile: profile) {
      switch profile.siteKind {
      case .zola:
        lines.append("extra:")
        lines.append("  \(profile.siteKind.coverFrontMatterFieldName): \(yamlString(coverPath))")
      case .astro, .hugo, .vitePress, .nextJS, .quartz, .foam, .hexo, .docusaurus, .mkDocs:
        lines.append("\(profile.siteKind.coverFrontMatterFieldName): \(yamlString(coverPath))")
      case .jekyll:
        lines.append("\(profile.siteKind.coverFrontMatterFieldName): \(yamlString(coverPath))")
      }
    }

    lines.append("---")
    return lines.joined(separator: "\n")
  }

  private func renderQuartzYAML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines = ["---", "title: \(yamlString(draft.title))"]
    if !draft.summary.trimmedForPublishing.isEmpty {
      lines.append("description: \(yamlString(draft.summary))")
    }
    lines.append("date: \(yamlString(formattedDate(draft.date, profile: profile)))")
    if !draft.tags.isEmpty {
      lines.append("tags: \(yamlArray(draft.tags))")
    }
    if !draft.aliases.isEmpty {
      lines.append("aliases: \(yamlArray(draft.aliases))")
    }
    if let permalink = draft.permalink?.nilIfEmpty {
      lines.append("permalink: \(yamlString(permalink))")
    }
    if profile.includeDraftFlagInFrontMatter {
      lines.append("draft: \(draft.draft ? "true" : "false")")
    }
    if let coverPath = frontMatterCoverPath(draft: draft, profile: profile) {
      lines.append("socialImage: \(yamlString(coverPath))")
    }
    lines.append("---")
    return lines.joined(separator: "\n")
  }

  private func renderDocumentationYAML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines = ["---", "title: \(yamlString(draft.title))"]
    if !draft.summary.trimmedForPublishing.isEmpty {
      lines.append("description: \(yamlString(draft.summary))")
    }
    if profile.siteKind != .mkDocs {
      lines.append("slug: \(yamlString(draft.slug))")
    }
    if !draft.tags.isEmpty, profile.siteKind != .astro {
      lines.append("tags: \(yamlArray(draft.tags))")
    }
    if profile.includeDraftFlagInFrontMatter {
      lines.append("draft: \(draft.draft ? "true" : "false")")
    }
    if profile.siteKind == .docusaurus,
      let coverPath = frontMatterCoverPath(draft: draft, profile: profile)
    {
      lines.append("image: \(yamlString(coverPath))")
    }
    lines.append("---")
    return lines.joined(separator: "\n")
  }

  private func renderTOML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines: [String] = ["+++"]
    lines.append("title = \(tomlString(draft.title))")
    lines.append(
      "\(dateFieldName(for: profile.siteKind)) = \(tomlString(formattedDate(draft.date, profile: profile)))"
    )
    lines.append("slug = \(tomlString(draft.slug))")
    if profile.siteKind == .hugo, let key = draft.translationKey?.trimmedForPublishing.nilIfEmpty {
      lines.append("translationKey = \(tomlString(key))")
    }

    if !draft.summary.trimmedForPublishing.isEmpty {
      lines.append("description = \(tomlString(draft.summary))")
    }

    let authors = effectiveAuthors(draft: draft, profile: profile)
    if !authors.isEmpty {
      lines.append("authors = \(tomlArray(authors))")
    }

    if profile.siteKind == .zola, !draft.tags.isEmpty || !draft.categories.isEmpty {
      var fields: [String] = []
      if !draft.tags.isEmpty { fields.append("tags = \(tomlArray(draft.tags))") }
      if !draft.categories.isEmpty { fields.append("categories = \(tomlArray(draft.categories))") }
      lines.append("taxonomies = { " + fields.joined(separator: ", ") + " }")
    } else if !draft.tags.isEmpty {
      lines.append("tags = \(tomlArray(draft.tags))")
    }

    if profile.siteKind != .zola, !draft.categories.isEmpty {
      lines.append("categories = \(tomlArray(draft.categories))")
    }

    if !draft.aliases.isEmpty {
      lines.append("aliases = \(tomlArray(draft.aliases))")
    }

    if let permalink = draft.permalink?.nilIfEmpty {
      lines.append("permalink = \(tomlString(permalink))")
    }

    if profile.includeDraftFlagInFrontMatter {
      if profile.siteKind == .foam {
        lines.append("status = \(tomlString(draft.draft ? "draft" : "published"))")
      } else {
        lines.append("draft = \(draft.draft ? "true" : "false")")
      }
    }

    if let coverPath = frontMatterCoverPath(draft: draft, profile: profile) {
      switch profile.siteKind {
      case .zola:
        lines.append("")
        lines.append("[extra]")
        lines.append("\(profile.siteKind.coverFrontMatterFieldName) = \(tomlString(coverPath))")
      case .astro, .hugo, .vitePress, .nextJS, .quartz, .foam, .hexo, .docusaurus, .mkDocs:
        lines.append("\(profile.siteKind.coverFrontMatterFieldName) = \(tomlString(coverPath))")
      case .jekyll:
        lines.append("\(profile.siteKind.coverFrontMatterFieldName) = \(tomlString(coverPath))")
      }
    }

    lines.append("+++")
    return lines.joined(separator: "\n")
  }

  private func effectiveAuthors(draft: ArticleDraft, profile: SiteProfile) -> [String] {
    if !draft.authors.isEmpty {
      return draft.authors
    }
    return profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? []
  }

  private func frontMatterCoverPath(draft: ArticleDraft, profile: SiteProfile) -> String? {
    guard !draft.isPrivate, profile.includeCoverInFrontMatter else {
      return nil
    }
    return coverPath(draft: draft)
  }

  private func coverPath(draft: ArticleDraft) -> String? {
    guard let coverAttachmentID = draft.coverAttachmentID else {
      return nil
    }
    return draft.attachments.first(where: { $0.id == coverAttachmentID })?.relativePublishPath
      .nilIfEmpty
  }

  private func formattedDate(_ date: Date, profile: SiteProfile) -> String {
    Self.formattedDate(date, format: profile.dateFormat.nilIfEmpty ?? "yyyy-MM-dd")
  }

  /// Shared with the imported-envelope path so both writers agree on locale and time zone.
  static func formattedDate(_ date: Date, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }

  private func dateFieldName(for siteKind: SiteKind) -> String {
    siteKind == .foam ? "created" : "date"
  }

  private func yamlArray(_ values: [String]) -> String {
    "[" + values.map(yamlString).joined(separator: ", ") + "]"
  }

  private func yamlString(_ value: String) -> String {
    "\"" + escapedString(value) + "\""
  }

  private func tomlArray(_ values: [String]) -> String {
    "[" + values.map(tomlString).joined(separator: ", ") + "]"
  }

  private func tomlString(_ value: String) -> String {
    "\"" + escapedString(value) + "\""
  }

  private func escapedString(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}
