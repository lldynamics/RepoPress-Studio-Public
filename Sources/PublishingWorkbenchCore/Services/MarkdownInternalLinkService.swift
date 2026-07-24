import Foundation

public struct MarkdownInternalLinkSuggestion: Identifiable, Hashable, Sendable {
  public var id: ArticleDraft.ID { draftID }
  public var draftID: ArticleDraft.ID
  public var title: String
  public var slug: String
  public var destination: String
  public var summary: String

  public init(
    draftID: ArticleDraft.ID,
    title: String,
    slug: String,
    destination: String,
    summary: String
  ) {
    self.draftID = draftID
    self.title = title
    self.slug = slug
    self.destination = destination
    self.summary = summary
  }
}

public struct MarkdownBacklink: Identifiable, Hashable, Sendable {
  public var id: ArticleDraft.ID { sourceDraftID }
  public var sourceDraftID: ArticleDraft.ID
  public var sourceTitle: String
  public var matchedDestination: String

  public init(sourceDraftID: ArticleDraft.ID, sourceTitle: String, matchedDestination: String) {
    self.sourceDraftID = sourceDraftID
    self.sourceTitle = sourceTitle
    self.matchedDestination = matchedDestination
  }
}

public enum MarkdownInternalLinkService {
  public static func suggestions(
    for currentDraft: ArticleDraft,
    among drafts: [ArticleDraft],
    profile: SiteProfile,
    query: String = ""
  ) -> [MarkdownInternalLinkSuggestion] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

    return drafts
      .filter {
        $0.id != currentDraft.id
          && !currentDraft.isGeneralDraft
          && $0.belongs(toSiteProfileID: currentDraft.siteProfileID)
      }
      .compactMap { draft in
        let title = draft.title.trimmedForPublishing
        let slug = draft.slug.trimmedForPublishing
        guard !title.isEmpty || !slug.isEmpty else { return nil }
        let searchable = [title, slug, draft.summary, draft.tags.joined(separator: " ")]
          .joined(separator: " ")
          .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard normalizedQuery.isEmpty || searchable.localizedStandardContains(normalizedQuery) else {
          return nil
        }
        return MarkdownInternalLinkSuggestion(
          draftID: draft.id,
          title: title.nilIfEmpty ?? slug,
          slug: slug,
          destination: destination(for: draft, profile: profile),
          summary: draft.summary
        )
      }
      .sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
  }

  public static func destination(for draft: ArticleDraft, profile: SiteProfile) -> String {
    let repositoryPath = draft.repositoryPath?.trimmedForPublishing.nilIfEmpty
    guard repositoryPath != nil || !draft.slug.trimmedForPublishing.isEmpty else {
      return "/"
    }

    let markdownPath = repositoryPath ?? profile.markdownPath(for: draft)
    return SiteArticleURLResolver().relativeWebPath(
      from: markdownPath,
      siteKind: profile.siteKind
    )
  }

  public static func markdownLink(
    to suggestion: MarkdownInternalLinkSuggestion,
    selectedText: String = ""
  ) -> String {
    let label = selectedText.trimmedForPublishing.nilIfEmpty ?? suggestion.title
    return "[\(label)](\(suggestion.destination))"
  }

  public static func backlinks(
    to target: ArticleDraft,
    among drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> [MarkdownBacklink] {
    let destination = destination(for: target, profile: profile)
    let normalizedTargetDestination = normalizedWebDestination(destination)
    let titleToken = "[[\(target.title.trimmedForPublishing)]]"

    return drafts.compactMap { source in
      guard source.id != target.id,
            !source.isGeneralDraft,
            target.belongs(toSiteProfileID: source.siteProfileID) else { return nil }
      let body = source.bodyMarkdown
      let matchedDestination = markdownLinkDestinations(in: body).first { candidate in
        normalizedWebDestination(candidate) == normalizedTargetDestination
      }
      let matchesTitle = !target.title.trimmedForPublishing.isEmpty && body.contains(titleToken)
      guard matchedDestination != nil || matchesTitle else { return nil }
      return MarkdownBacklink(
        sourceDraftID: source.id,
        sourceTitle: source.title,
        matchedDestination: matchedDestination ?? titleToken
      )
    }
    .sorted { $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending }
  }

  private static let markdownLinkDestinationExpression = try? NSRegularExpression(
    pattern: #"(?<!!)\[[^\]\n]*\]\(\s*<?([^\s)>]+)>?"#
  )

  private static func markdownLinkDestinations(in markdown: String) -> [String] {
    guard let markdownLinkDestinationExpression else { return [] }
    let source = markdown as NSString
    let matches = markdownLinkDestinationExpression.matches(
      in: markdown,
      range: NSRange(location: 0, length: source.length)
    )
    return matches.compactMap { match in
      guard match.numberOfRanges > 1,
            match.range(at: 1).location != NSNotFound else {
        return nil
      }
      return source.substring(with: match.range(at: 1))
    }
  }

  private static func normalizedWebDestination(_ destination: String) -> String? {
    let trimmed = destination.trimmedForPublishing
    guard !trimmed.isEmpty else { return nil }

    guard let components = URLComponents(string: trimmed) else { return nil }
    if let scheme = components.scheme?.lowercased(), !["http", "https"].contains(scheme) {
      return nil
    }

    let encodedPath = components.percentEncodedPath
    guard !encodedPath.isEmpty else { return nil }
    let decodedPath = encodedPath.removingPercentEncoding ?? encodedPath
    let normalizedPath = decodedPath.normalizedRelativePath()
    return normalizedPath.isEmpty ? "/" : "/\(normalizedPath)/"
  }
}
