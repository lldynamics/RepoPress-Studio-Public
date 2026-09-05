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
}
