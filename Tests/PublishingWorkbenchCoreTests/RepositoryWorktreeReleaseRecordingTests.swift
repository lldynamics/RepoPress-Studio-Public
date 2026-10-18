import Foundation
import PublishingGitCore
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryWorktreeReleaseRecordingTests: XCTestCase {
  func testArticleTargetRequiresPublicExactMaterializedContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-target-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = SiteProfile(name: "Test", localRepositoryRootPath: root.path)
    var draft = ArticleDraft(
      siteProfileID: profile.id, title: "Article", draft: false,
      bodyMarkdown: "Reviewed body", repositoryPath: "article.md"
    )
    let document = FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    try Data(document.utf8).write(to: root.appendingPathComponent("article.md"))
    let git = GitCommandRunner()
    XCTAssertEqual(git.run(["init"], rootURL: root).terminationStatus, 0)
    let blob = git.run(["hash-object", "article.md"], rootURL: root).standardOutput
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = RepositoryWorktreePublishSnapshot(
      repositoryRoot: root.path, gitCommonDirectory: root.appendingPathComponent(".git").path,
      branch: "main", headSHA: "base", originURL: "https://example.invalid/site.git",
      remoteBranchSHA: "base", statusFingerprint: " M article.md",
      entries: [.init(kind: .modified, status: " M", path: "article.md", blobOID: blob)]
    )
    XCTAssertNotNil(
      RepositoryWorktreeArticleVerificationTarget.capture(
        draft: draft, profile: profile, snapshot: snapshot))
    draft.visibility = .private
    XCTAssertNil(
      RepositoryWorktreeArticleVerificationTarget.capture(
        draft: draft, profile: profile, snapshot: snapshot))
    draft.visibility = .public
    draft.bodyMarkdown = "A later editor revision"
    XCTAssertNil(
      RepositoryWorktreeArticleVerificationTarget.capture(
        draft: draft, profile: profile, snapshot: snapshot))
  }

  func testOnlyAnExactConfirmedRemoteCommitCanCreateDeploymentRecord() {
    let profile = SiteProfile(name: "Test", repoOwner: "owner", repoName: "site", branch: "main")
    let target = RepositoryWorktreeArticleVerificationTarget(
      draftID: UUID(), title: "Frozen article", summary: "Frozen summary",
      markdownPath: "content/a.md"
    )
    let good = RepositoryWorktreePublishResult(
      commitSHA: "abc", branch: "main", pushed: true, remoteCommitSHA: "abc",
      committedPaths: ["content/a.md", "style.css"]
    )
    let record = ReleaseRecord.confirmedWorktreePush(
      result: good, profile: profile, article: target)
    XCTAssertEqual(record?.kind, .remoteDirectCommit)
    XCTAssertEqual(record?.deploymentCommitSHA, "abc")
    XCTAssertEqual(record?.markdownPath, "content/a.md")
    XCTAssertEqual(record?.draftTitle, "Frozen article")
    XCTAssertEqual(record?.changedPaths, good.committedPaths)

    let mismatched = RepositoryWorktreePublishResult(
      commitSHA: "abc", branch: "main", pushed: true, remoteCommitSHA: "other",
      committedPaths: good.committedPaths
    )
    XCTAssertNil(
      ReleaseRecord.confirmedWorktreePush(result: mismatched, profile: profile, article: target))
    let unconfirmed = RepositoryWorktreePublishResult(
      commitSHA: "abc", branch: "main", pushed: false, remoteCommitSHA: nil,
      committedPaths: good.committedPaths
    )
    XCTAssertNil(
      ReleaseRecord.confirmedWorktreePush(result: unconfirmed, profile: profile, article: target))
  }

  func testConfigurationOnlyPublishDoesNotClaimToHavePublishedSelectedArticle() {
    let profile = SiteProfile(name: "Test")
    let target = RepositoryWorktreeArticleVerificationTarget(
      draftID: UUID(), title: "Unchanged article", summary: "", markdownPath: "content/a.md"
    )
    let result = RepositoryWorktreePublishResult(
      commitSHA: "abc", branch: "main", pushed: true, remoteCommitSHA: "abc",
      committedPaths: ["style.css"]
    )
    let record = ReleaseRecord.confirmedWorktreePush(
      result: result, profile: profile, article: target)
    XCTAssertNotNil(record)
    XCTAssertNil(record?.markdownPath)
    XCTAssertNil(record?.draftID)
  }

  func testTrackingRequestDefaultsOffAndRequiresAConfirmedArticleTarget() {
    let profile = SiteProfile(name: "Test", repoOwner: "owner", repoName: "site", branch: "main")
    let target = RepositoryWorktreeArticleVerificationTarget(
      draftID: UUID(), title: "Article", summary: "", markdownPath: "content/a.md")
    let result = RepositoryWorktreePublishResult(
      commitSHA: "abc", branch: "main", pushed: true, remoteCommitSHA: "abc",
      committedPaths: ["content/a.md"])

    let defaultRecord = ReleaseRecord.confirmedWorktreePush(
      result: result, profile: profile, article: target)
    XCTAssertNil(defaultRecord?.articlePublishTrackingRequest)
    let scopedRecord = ReleaseRecord.confirmedWorktreePush(
      result: result, profile: profile, article: target, trackingRequested: true)
    XCTAssertNotNil(scopedRecord?.articlePublishTrackingRequest)
    let missingTargetRecord = ReleaseRecord.confirmedWorktreePush(
      result: result, profile: profile, article: nil, trackingRequested: true)
    XCTAssertNil(missingTargetRecord?.articlePublishTrackingRequest)
  }

  func testRecoveryReceiptDecodesLegacyTrackingFieldAndDistinguishesScopedPublish() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-recovery-receipt-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = SiteProfile(
      name: "Test", localRepositoryRootPath: root.path, repoOwner: "owner", repoName: "site",
      branch: "main", deploymentProvider: .custom,
      deploymentSiteURL: "https://old.example.invalid",
      deploymentStatusEndpointURL: "https://old.example.invalid/status")
    let snapshot = RepositoryWorktreePublishSnapshot(
      repositoryRoot: root.path,
      gitCommonDirectory: root.appendingPathComponent(".git").path,
      branch: "main", headSHA: String(repeating: "0", count: 40), originURL: root.path,
      remoteBranchSHA: String(repeating: "0", count: 40), statusFingerprint: "",
      entries: [])
    let target = RepositoryWorktreeArticleVerificationTarget(
      draftID: UUID(), title: "Article", summary: "", markdownPath: "content/a.md")
    let seedDate = Date(timeIntervalSince1970: 1_700_000_123)
    let seed = ArticlePublishTrackingRequest(profile: profile, now: seedDate)
    func receipt(
      scoped: Bool, trackingRequest: ArticlePublishTrackingRequest? = nil
    ) throws -> RepositoryWorktreePushRecoveryRecord {
      let confirmation = RepositoryWorktreePublishConfirmation(
        snapshot: snapshot, commitMessage: "Publish",
        articleVerificationTarget: scoped ? target : nil,
        pathScope: scoped ? ["content/a.md"] : nil)
      return RepositoryWorktreePushRecoveryRecord(
        profile: profile, confirmation: confirmation,
        commitSHA: String(repeating: scoped ? "a" : "b", count: 40),
        trackingRequest: trackingRequest)
    }

    let scoped = try receipt(scoped: true, trackingRequest: seed)
    let all = try receipt(scoped: false)
    XCTAssertEqual(scoped.articleTrackingRequest, seed)
    XCTAssertNil(all.articleTrackingRequest)

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(scoped)) as? [String: Any])
    legacyObject.removeValue(forKey: "articleTrackingRequest")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let decodedLegacy = try JSONDecoder().decode(
      RepositoryWorktreePushRecoveryRecord.self, from: legacyData)
    XCTAssertNil(decodedLegacy.articleTrackingRequest)

    var changedProfile = profile
    changedProfile.deploymentStatusEndpointURL = "https://new.example.invalid/status"
    let result = RepositoryWorktreePublishResult(
      commitSHA: String(repeating: "c", count: 40), branch: "main", pushed: true,
      remoteCommitSHA: String(repeating: "c", count: 40), committedPaths: ["content/a.md"])
    let record = ReleaseRecord.confirmedWorktreePush(
      result: result, profile: changedProfile, article: target, trackingRequest: seed)
    let recordedRequest = try XCTUnwrap(record?.articlePublishTrackingRequest)
    XCTAssertEqual(recordedRequest.target, seed.target)
    XCTAssertEqual(recordedRequest.startedAt, seed.startedAt)
    XCTAssertEqual(record?.localWriteResolutionCutoff, seed.startedAt)
    XCTAssertEqual(recordedRequest.deadline, seed.deadline)
  }

  @MainActor
  func testConfirmedPushUsesFrozenArticleBaselineWithoutDiscardingLaterLocalEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-worktree-release-recording-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let persistenceURL = root.appendingPathComponent("workbench.json")
    let profile = SiteProfile(
      name: "Test",
      localRepositoryRootPath: root.path,
      repoOwner: "owner",
      repoName: "site",
      branch: "main"
    )
    let markdownPath = "content/a.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Frozen article",
      draft: false,
      summary: "Frozen summary",
      bodyMarkdown: "Frozen body",
      status: .ready,
      repositoryPath: markdownPath
    )
    let frozenDocument = FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    let frozenDigest = ArticleDraft.repositoryDocumentDigest(frozenDocument)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: markdownPath,
      renderedContentDigest: frozenDigest,
      projectFileContentDigest: frozenDigest
    )
    let frozenBlobOID = String(repeating: "a", count: 40)
    let frozenArticle = RepositoryWorktreeArticleVerificationTarget(
      draftID: draft.id,
      title: draft.title,
      summary: draft.summary,
      markdownPath: markdownPath,
      sourceDocumentDigest: frozenDigest,
      repositoryBlobOID: frozenBlobOID
    )

    draft.bodyMarkdown = "Later local body"
    draft.summary = "Later local summary"
    XCTAssertNotEqual(draft.renderedRepositoryContentDigest(profile: profile), frozenDigest)
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion,
      releaseRecords: []
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: snapshot))
    )
    let result = RepositoryWorktreePublishResult(
      commitSHA: String(repeating: "b", count: 40),
      branch: "main",
      pushed: true,
      remoteCommitSHA: String(repeating: "b", count: 40),
      committedPaths: [markdownPath]
    )

    store.recordConfirmedWorktreePush(
      result, profile: profile, article: frozenArticle, trackingRequested: true)

    let updatedDraft = try XCTUnwrap(store.publishingStore.drafts.first)
    XCTAssertEqual(updatedDraft.bodyMarkdown, "Later local body")
    XCTAssertEqual(updatedDraft.summary, "Later local summary")
    XCTAssertEqual(updatedDraft.status, .ready)
    XCTAssertFalse(updatedDraft.draft)
    XCTAssertEqual(updatedDraft.repositoryBinding?.remoteRevision, frozenBlobOID)
    XCTAssertEqual(updatedDraft.repositoryBinding?.renderedContentDigest, frozenDigest)
    XCTAssertEqual(updatedDraft.repositorySyncState(for: profile), .localChanged)
    let release = try XCTUnwrap(store.releaseRecords.first)
    let trackingRequest = try XCTUnwrap(release.articlePublishTrackingRequest)
    XCTAssertEqual(release.draftTitle, "Frozen article")
    XCTAssertEqual(release.draftSummary, "Frozen summary")
    XCTAssertEqual(release.sourceDocumentDigest, frozenDigest)

    store.recordConfirmedWorktreePush(result, profile: profile, article: frozenArticle)

    XCTAssertEqual(store.releaseRecords.count, 1)
    XCTAssertEqual(store.releaseRecords.first?.id, release.id)
    XCTAssertEqual(store.publishingStore.drafts.first?.bodyMarkdown, "Later local body")
    XCTAssertEqual(store.publishingStore.drafts.first?.summary, "Later local summary")
    XCTAssertEqual(store.publishingStore.drafts.first?.status, .ready)
    XCTAssertEqual(
      store.publishingStore.drafts.first?.repositorySyncState(for: profile),
      .localChanged
    )
    XCTAssertEqual(store.releaseRecords.first?.articlePublishTrackingRequest, trackingRequest)
    await store.waitForPendingSave()
  }
}

final class ReleaseLedgerLocalWriteResolutionTests: XCTestCase {
  private func records() -> (ReleaseRecord, ReleaseRecord) {
    let profile = SiteProfile(name: "Test", repoOwner: "owner", repoName: "site", branch: "main")
    let local = ReleaseRecord(
      kind: .localWrite, title: "Local write", summary: "",
      siteProfileID: profile.id, draftID: UUID(), sourceDocumentDigest: "frozen-source",
      markdownPath: "article.md", changedPaths: ["article.md", "image.png"],
      repositoryProvider: profile.repositoryProvider, repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner, repoName: profile.repoName, branchName: profile.branch,
      createdAt: Date(timeIntervalSince1970: 100))
    var push = local
    push.id = UUID()
    push.kind = .remoteDirectCommit
    push.commitSHA = "confirmed-commit"
    push.targetBranch = "main"
    push.articlePublishTrackingRequest = ArticlePublishTrackingRequest(
      profile: profile, now: Date(timeIntervalSince1970: 110))
    push.localWriteResolutionCutoff = Date(timeIntervalSince1970: 110)
    push.createdAt = Date(timeIntervalSince1970: 120)
    return (local, push)
  }

  func testConfirmedPushRetiresOnlyMatchingActionAndKeepsHistoryAfterReload() throws {
    let (local, push) = records()
    var other = local
    other.id = UUID()
    other.draftID = UUID()
    let saved = try JSONEncoder().encode([push, local, other])
    let restored = try JSONDecoder().decode([ReleaseRecord].self, from: saved)
    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: restored, deploymentStatusSnapshots: [:])
    XCTAssertEqual(ledger.entries.count, 3)
    XCTAssertEqual(ledger.summary.localPendingCount, 1)
    XCTAssertFalse(ledger.actionItems.contains { $0.recordID == local.id })
    XCTAssertTrue(
      ledger.actionItems.contains {
        $0.recordID == other.id && $0.kind == .publishLocalChanges
      })
    XCTAssertTrue(
      ledger.actionItems.contains {
        $0.recordID == push.id && $0.kind == .observeDeployment
      })
  }

  func testLegacyPushWithoutFrozenBoundaryRemainsConservative() throws {
    let (local, push) = records()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(push)) as? [String: Any])
    object.removeValue(forKey: "localWriteResolutionCutoff")
    let legacy = try JSONDecoder().decode(
      ReleaseRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.localWriteResolutionCutoff)
    XCTAssertTrue(ReleaseLedgerLocalWriteResolution.resolvedIDs(in: [local, legacy]).isEmpty)
  }

  func testDeploymentRecheckCannotChangeWhichLocalWritesWerePublished() throws {
    let (local, originalPush) = records()
    var push = originalPush
    let profile = SiteProfile(
      id: try XCTUnwrap(local.siteProfileID), name: "Test",
      repoOwner: "owner", repoName: "site", branch: "main")
    push.articlePublishTrackingRequest = ArticlePublishTrackingRequest(
      profile: profile, now: Date(timeIntervalSince1970: 200))
    var later = local
    later.id = UUID()
    later.createdAt = Date(timeIntervalSince1970: 115)
    XCTAssertEqual(
      ReleaseLedgerLocalWriteResolution.resolvedIDs(in: [local, later, push]), [local.id])
  }

  func testUnconfirmedPartialOrDifferentDestinationCannotRetireLocalAction() {
    let (local, push) = records()
    let changes: [(inout ReleaseRecord) -> Void] = [
      { $0.kind = .remotePublishFailure }, { $0.kind = .directCommit },
      { $0.kind = .remoteReviewRequest }, { $0.commitSHA = nil },
      { $0.articlePublishTrackingRequest = nil }, { $0.localWriteResolutionCutoff = nil },
      { $0.changedPaths = ["article.md"] },
      { $0.siteProfileID = UUID() }, { $0.draftID = UUID() },
      { $0.sourceDocumentDigest = "different-version" }, { $0.repoName = "other" },
      { $0.repositoryBaseURL = "https://other.invalid" },
      { $0.branchName = "other" }, { $0.targetBranch = "other" },
      { $0.markdownPath = "other.md" },
    ]
    for change in changes {
      var candidate = push
      change(&candidate)
      XCTAssertTrue(ReleaseLedgerLocalWriteResolution.resolvedIDs(in: [local, candidate]).isEmpty)
    }
  }

  func testLaterWritesLegacyUnknownBranchAndBatchRemaindersStayPending() {
    let (local, push) = records()
    let changes: [(inout ReleaseRecord) -> Void] = [
      { $0.createdAt = Date(timeIntervalSince1970: 111) },
      { $0.sourceDocumentDigest = nil }, { $0.branchName = nil },
      { $0.changedPaths.append("unpublished.md") }, { $0.changedPaths = [] },
      { $0.kind = .batchLocalWrite },
    ]
    for change in changes {
      var candidate = local
      change(&candidate)
      XCTAssertTrue(ReleaseLedgerLocalWriteResolution.resolvedIDs(in: [candidate, push]).isEmpty)
    }
  }
}
