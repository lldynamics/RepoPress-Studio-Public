import Foundation

public struct SiteUnpublishImpactSource: Identifiable, Hashable, Sendable {
  public let id: String
  public let sourceDraftID: UUID
  public let sourceTitle: String
  public let sourceURL: String?
  public let anchorText: String
  public let target: String

  init(reference: SiteLinkReference, source: ArticleDraft, profile: SiteProfile) {
    id = reference.id
    sourceDraftID = source.id
    sourceTitle = source.title.nilIfEmpty ?? CoreL10n.text("未命名文章")
    sourceURL = SiteArticleURLResolver().relativeWebPath(
      from: source.repositoryPath ?? profile.markdownPath(for: source), profile: profile
    )
    anchorText = reference.anchorText
    target = reference.target
  }
}

/// Retains all parsing inputs, including articles that did not yet link to the
/// target, so a newly added reference cannot bypass confirmation.
public struct SiteUnpublishImpactSnapshot: Hashable, Sendable {
  public let targetDraft: ArticleDraft
  public let profileSnapshot: SiteProfile
  public let sources: [SiteUnpublishImpactSource]
  let candidateDrafts: [ArticleDraft]

  public var targetDraftID: UUID { targetDraft.id }
  public var sourceArticleCount: Int { Set(sources.map(\.sourceDraftID)).count }
  public var referenceCount: Int { sources.count }

  public func remainsValid(
    target: ArticleDraft, sources currentSources: [ArticleDraft], profile: SiteProfile
  ) -> Bool {
    target == targetDraft && profile == profileSnapshot
      && target.belongs(toSiteProfileID: profile.id) && !target.isGeneralDraft
      && currentSources.contains(where: { $0.id == target.id })
      && candidateDrafts == Self.candidates(currentSources, profileID: profile.id)
  }

  fileprivate static func candidates(_ drafts: [ArticleDraft], profileID: UUID) -> [ArticleDraft] {
    drafts.filter { $0.belongs(toSiteProfileID: profileID) && !$0.isGeneralDraft }
      .sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

public struct SiteUnpublishImpactService: Sendable {
  private let auditService: SiteLinkAuditService

  public init(auditService: SiteLinkAuditService = SiteLinkAuditService()) {
    self.auditService = auditService
  }

  /// Callers supply active drafts; recycled documents are a separate store.
  /// This invokes only local link parsing, never external link probing.
  public func preview(
    target: ArticleDraft, drafts: [ArticleDraft], profile: SiteProfile
  ) -> SiteUnpublishImpactSnapshot {
    let eligible = SiteUnpublishImpactSnapshot.candidates(drafts, profileID: profile.id)
    let report = auditService.report(drafts: eligible, profile: profile)
    let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
    let sources = report.references(to: target.id).compactMap {
      reference -> SiteUnpublishImpactSource? in
      guard reference.sourceDraftID != target.id,
        reference.resolution == .validInternal || reference.resolution == .pendingSlugRedirect,
        let source = byID[reference.sourceDraftID]
      else { return nil }
      return SiteUnpublishImpactSource(reference: reference, source: source, profile: profile)
    }
    return SiteUnpublishImpactSnapshot(
      targetDraft: target, profileSnapshot: profile,
      sources: sources.sorted { lhs, rhs in
        let order = lhs.sourceTitle.localizedStandardCompare(rhs.sourceTitle)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
      },
      candidateDrafts: eligible
    )
  }

  public func previewAsync(
    target: ArticleDraft, drafts: [ArticleDraft], profile: SiteProfile
  ) async throws -> SiteUnpublishImpactSnapshot {
    try Task.checkCancellation()
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let result = preview(target: target, drafts: drafts, profile: profile)
      try Task.checkCancellation()
      return result
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
