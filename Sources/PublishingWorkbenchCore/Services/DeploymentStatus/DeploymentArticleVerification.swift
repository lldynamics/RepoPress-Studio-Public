import Foundation

/// The exact article and document reviewed for this release, independent of later edits.
public struct DeploymentArticleVerificationResult: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { target.draftID }
  public var target: ReleaseRecordBatchItem
  public var checkedAt: Date
  public var signals: [DeploymentStatusSignal]

  public init(
    target: ReleaseRecordBatchItem, checkedAt: Date = Date(), signals: [DeploymentStatusSignal]
  ) {
    self.target = target
    self.checkedAt = checkedAt
    self.signals = signals
  }

  /// A successful page fetch or matching title does not establish the source version.
  public var verifiesSourceVersion: Bool {
    guard let expected = target.sourceDocumentDigest,
      ArticleSourceVersionEvidence.normalizedDigest(expected) != nil
    else { return false }
    return signals.contains {
      $0.level == .success
        && $0.verifiedSourceDocumentDigest?.caseInsensitiveCompare(expected) == .orderedSame
    }
  }

  public var level: DeploymentStatusLevel {
    if signals.contains(where: { $0.level == .failed }) { return .failed }
    if signals.contains(where: { $0.level == .running }) { return .running }
    return !signals.isEmpty && signals.allSatisfy { $0.level == .success } ? .success : .unknown
  }
}

extension ReleaseRecord {
  public var articleVerificationTargets: [ReleaseRecordBatchItem] {
    if !batchItems.isEmpty { return batchItems }
    guard let markdownPath else { return [] }
    // Legacy records can still be checked even when the local draft no longer exists.
    let draftID = draftID ?? id
    return [
      ReleaseRecordBatchItem(
        draftID: draftID, draftTitle: draftTitle ?? title, markdownPath: markdownPath,
        draftSummary: draftSummary, draftCoverAltText: draftCoverAltText,
        publicPath: publicPath, publicURLText: publicURLText,
        sourceDocumentDigest: sourceDocumentDigest, changedPaths: changedPaths)
    ]
  }

  func projectingArticle(_ target: ReleaseRecordBatchItem) -> ReleaseRecord {
    var record = self
    record.draftID = target.draftID
    record.draftTitle = batchItems.isEmpty ? draftTitle : target.draftTitle
    record.draftSummary = target.draftSummary
    record.draftCoverAltText = target.draftCoverAltText
    record.markdownPath = target.markdownPath
    record.publicPath = target.publicPath
    record.publicURLText = target.publicURLText
    record.sourceDocumentDigest = target.sourceDocumentDigest
    record.batchItems = []
    return record
  }
}

extension DeploymentStatusSnapshot {
  public func verifiesAllArticles(in record: ReleaseRecord) -> Bool {
    let targets = record.articleVerificationTargets
    return targets.isEmpty
      || targets.allSatisfy { target in
        articleResults?.contains(where: { $0.target == target && $0.level == .success && $0.verifiesSourceVersion }) == true
      }
  }

  public func verifiesArticle(_ target: ReleaseRecordBatchItem, in record: ReleaseRecord) -> Bool {
    guard releaseRecordID == record.id, profileID == record.siteProfileID,
      let expected = record.deploymentCommitSHA,
      expectedCommitSHA?.caseInsensitiveCompare(expected) == .orderedSame,
      expectedBranch == record.deploymentBranchName,
      attributionVerified == true, platformLevel == .success
    else { return false }
    return articleResults?.contains(where: { $0.target == target && $0.level == .success && $0.verifiesSourceVersion }) == true
  }
}

extension WorkbenchStore {
  /// A page check must never publish newer, unsaved article content by association.
  func markVerifiedArticlesAsPublished(
    record: ReleaseRecord, snapshot: DeploymentStatusSnapshot, profile: SiteProfile,
    allowedDraftIDs: Set<UUID>? = nil
  ) {
    guard
      record.kind == .remoteDirectCommit
        || (record.kind == .remoteReviewRequest && record.reviewStatus?.state == .merged),
      record.siteProfileID == profile.id
    else { return }
    let verified = record.articleVerificationTargets.filter {
      snapshot.verifiesArticle($0, in: record)
    }
    var changed = false
    for target in verified {
      guard allowedDraftIDs?.contains(target.draftID) != false else { continue }
      guard let index = publishingStore.drafts.firstIndex(where: { $0.id == target.draftID }) else {
        continue
      }
      let draft = publishingStore.drafts[index]
      guard !draft.draft, draft.visibility == .public, draft.status != .published,
        draft.belongs(toSiteProfileID: profile.id),
        profile.markdownPath(for: draft) == target.markdownPath,
        let digest = target.sourceDocumentDigest,
        draft.renderedRepositoryContentDigest(profile: profile) == digest,
        !draftBodyEditorBuffer(for: draft.id).isDirty
      else { continue }
      var updated = draft
      updated.status = .published
      updated.markUpdated(at: Date(), replacing: draft)
      publishingStore.drafts[index] = updated
      publishingStore.removeDraftPublishPreviewSnapshot(for: draft.id)
      changed = true
    }
    if changed { invalidateDraftDerivedCaches() }
  }
}

extension PublishPackage {
  /// Conflict resolution can replace the reviewed Markdown without rebuilding its
  /// envelope. Freeze verification metadata from the actual upload in that case.
  func freezingArticleVerification(finalFiles: [PublishPackageFile], profile: SiteProfile)
    -> PublishPackage
  {
    guard
      let document = finalFiles.first(where: {
        $0.kind == .markdown && $0.operation == .upsert && $0.repositoryPath == markdownPath
      })?.content
    else { return self }
    let digest = ArticleDraft.repositoryDocumentDigest(document)
    guard let sourceDocumentDigest, sourceDocumentDigest != digest else { return self }
    var updated = self
    let imported = LocalContentImportService().importDraft(
      document: document, repositoryPath: markdownPath, profile: profile)
    guard imported.issues.isEmpty, imported.skippedPaths.isEmpty,
      imported.importedDrafts.count == 1, let draft = imported.importedDrafts.first
    else {
      // Do not verify a route or content snapshot that no longer represents the upload.
      updated.publicURLText = ""
      updated.sourceDocumentDigest = nil
      return updated
    }
    updated.title = draft.title
    updated.draftSummary = draft.summary.trimmedForPublishing.nilIfEmpty
    updated.draftCoverAltText =
      draft.attachments.first(where: { $0.id == draft.coverAttachmentID })?.altText
    updated.publicPath = SiteArticleURLResolver().relativeWebPath(
      from: markdownPath, profile: profile, permalink: draft.permalink)
    updated.publicURLText = updated.publicPath.flatMap {
      DeploymentStatusService().publicArticleURL(profile: profile, publicPath: $0)
    }
    updated.sourceDocumentDigest = digest
    return updated
  }
}
