import Foundation

public struct SlugChangeImpact: Hashable, Sendable {
  public var targetDraftID: UUID
  public var targetTitle: String
  public var oldRoutes: [String]
  public var newRoute: String
  public var references: [SiteLinkReference]
  public var conflictingAliasRoutes: [String]

  public init(
    targetDraftID: UUID,
    targetTitle: String,
    oldRoutes: [String],
    newRoute: String,
    references: [SiteLinkReference],
    conflictingAliasRoutes: [String]
  ) {
    self.targetDraftID = targetDraftID
    self.targetTitle = targetTitle
    self.oldRoutes = oldRoutes
    self.newRoute = newRoute
    self.references = references
    self.conflictingAliasRoutes = conflictingAliasRoutes
  }

  public var affectedDraftCount: Int {
    Set(references.map(\.sourceDraftID)).count
  }

  public var referenceCount: Int {
    references.count
  }
}

public struct SlugChangeApplicationResult: Hashable, Sendable {
  public var wasApplied: Bool
  public var affectedDraftCount: Int
  public var referenceCount: Int
  public var message: String

  public init(
    wasApplied: Bool,
    affectedDraftCount: Int = 0,
    referenceCount: Int = 0,
    message: String
  ) {
    self.wasApplied = wasApplied
    self.affectedDraftCount = affectedDraftCount
    self.referenceCount = referenceCount
    self.message = message
  }
}

public struct SlugChangeRedirectService: Sendable {
  public init() {}

  public func impact(
    target: ArticleDraft,
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) -> SlugChangeImpact? {
    let oldRoutes = target.pendingSlugRedirectPaths
      .map(normalizedRoute)
      .filter { $0 != "/" }
      .uniquedPreservingOrder()
    guard !oldRoutes.isEmpty else { return nil }
    let newRoute = normalizedRoute(
      SiteArticleURLResolver().relativeWebPath(
        from: profile.markdownPath(for: target),
        profile: profile,
        permalink: target.permalink
      )
    )
    let report = SiteLinkAuditService().report(drafts: drafts, profile: profile)
    let references = report.references(
      to: target.id,
      resolution: .pendingSlugRedirect
    )
    let conflicting = oldRoutes.filter { oldRoute in
      drafts.contains { candidate in
        guard candidate.id != target.id, !candidate.isGeneralDraft else { return false }
        let canonical = normalizedRoute(
          SiteArticleURLResolver().relativeWebPath(
            from: profile.markdownPath(for: candidate),
            profile: profile,
            permalink: candidate.permalink
          )
        )
        return canonical == oldRoute
          || candidate.aliases.map(normalizedRoute).contains(oldRoute)
      }
    }
    return SlugChangeImpact(
      targetDraftID: target.id,
      targetTitle: target.title.nilIfEmpty ?? target.slug,
      oldRoutes: oldRoutes,
      newRoute: newRoute,
      references: references,
      conflictingAliasRoutes: conflicting
    )
  }

  public func replacementBodies(
    for impact: SlugChangeImpact,
    target: ArticleDraft,
    drafts: [ArticleDraft]
  ) -> [UUID: String]? {
    let draftsByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    let grouped = Dictionary(grouping: impact.references, by: \.sourceDraftID)
    var replacements: [UUID: String] = [:]
    for (draftID, references) in grouped {
      guard let draft = draftsByID[draftID] else { return nil }
      let source = draft.bodyMarkdown as NSString
      var body = draft.bodyMarkdown
      for reference in references.sorted(by: {
        $0.targetUTF16Range.location > $1.targetUTF16Range.location
      }) {
        let range = reference.targetUTF16Range
        guard range.location >= 0,
          NSMaxRange(range) <= source.length,
          impact.oldRoutes.contains(
            reference.normalizedTarget.map(normalizedRoute)
              ?? normalizedRoute(source.substring(with: range))
          )
            || reference.syntax == .wiki
        else { return nil }
        let replacement: String
        if reference.syntax == .wiki {
          replacement = target.slug.trimmedForPublishing.nilIfEmpty
            ?? impact.newRoute.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
          replacement = impact.newRoute
        }
        body = (body as NSString).replacingCharacters(in: range, with: replacement)
      }
      replacements[draftID] = body
    }
    return replacements
  }

  private func normalizedRoute(_ value: String) -> String {
    var path = value.trimmedForPublishing
    path = String(path.split(separator: "#", maxSplits: 1).first ?? "")
    path = String(path.split(separator: "?", maxSplits: 1).first ?? "")
    let components = path.split(separator: "/").map(String.init)
    return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))/"
  }
}

private extension Sequence where Element == String {
  func uniquedPreservingOrder() -> [String] {
    var seen = Set<String>()
    return filter { seen.insert($0).inserted }
  }
}
