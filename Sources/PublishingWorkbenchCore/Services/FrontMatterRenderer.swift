import Foundation

public struct FrontMatterRenderer: Sendable {
  public init() {}

  public func render(draft: ArticleDraft, profile: SiteProfile) -> String {
    switch profile.frontMatterStyle {
    case .yaml:
      return renderYAML(draft: draft, profile: profile)
    case .toml:
      return renderTOML(draft: draft, profile: profile)
    }
  }

  public func renderDocument(draft: ArticleDraft, profile: SiteProfile) -> String {
    let body = draft.bodyMarkdown.trimmingCharacters(in: .newlines)
    return render(draft: draft, profile: profile) + "\n\n" + body + "\n"
  }

  private func renderYAML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines: [String] = ["---"]
    lines.append("title: \(yamlString(draft.title))")
    lines.append("\(dateFieldName(for: profile.siteKind)): \(yamlString(formattedDate(draft.date, profile: profile)))")
    lines.append("slug: \(yamlString(draft.slug))")

    if !draft.summary.trimmedForPublishing.isEmpty {
      lines.append("description: \(yamlString(draft.summary))")
    }

    let authors = effectiveAuthors(draft: draft, profile: profile)
    if !authors.isEmpty {
      lines.append("authors: \(yamlArray(authors))")
    }

    if !draft.tags.isEmpty {
      lines.append("tags: \(yamlArray(draft.tags))")
    }

    if !draft.categories.isEmpty {
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
      case .astro, .hugo, .vitePress, .nextJS, .quartz, .foam, .hexo:
        lines.append("\(profile.siteKind.coverFrontMatterFieldName): \(yamlString(coverPath))")
      case .jekyll:
        lines.append("\(profile.siteKind.coverFrontMatterFieldName): \(yamlString(coverPath))")
      }
    }

    lines.append("---")
    return lines.joined(separator: "\n")
  }

  private func renderTOML(draft: ArticleDraft, profile: SiteProfile) -> String {
    var lines: [String] = ["+++"]
    lines.append("title = \(tomlString(draft.title))")
    lines.append("\(dateFieldName(for: profile.siteKind)) = \(tomlString(formattedDate(draft.date, profile: profile)))")
    lines.append("slug = \(tomlString(draft.slug))")

    if !draft.summary.trimmedForPublishing.isEmpty {
      lines.append("description = \(tomlString(draft.summary))")
    }

    let authors = effectiveAuthors(draft: draft, profile: profile)
    if !authors.isEmpty {
      lines.append("authors = \(tomlArray(authors))")
    }

    if !draft.tags.isEmpty {
      lines.append("tags = \(tomlArray(draft.tags))")
    }

    if !draft.categories.isEmpty {
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
      case .astro, .hugo, .vitePress, .nextJS, .quartz, .foam, .hexo:
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
    return draft.attachments.first(where: { $0.id == coverAttachmentID })?.relativePublishPath.nilIfEmpty
  }

  private func formattedDate(_ date: Date, profile: SiteProfile) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = profile.dateFormat.nilIfEmpty ?? "yyyy-MM-dd"
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
