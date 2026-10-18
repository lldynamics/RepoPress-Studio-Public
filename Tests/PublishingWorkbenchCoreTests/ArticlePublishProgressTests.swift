import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class ArticlePublishProgressTests: XCTestCase {
  func testOnlineRequiresMatchingReleaseIdentityAndArticleDigest() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now)
    let snapshot = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .success, attribution: true,
      articleLevel: .success, digest: record.articleVerificationTargets[0].sourceDocumentDigest)

    XCTAssertEqual(
      ArticlePublishProgress.make(record: record, snapshot: snapshot, profile: profile, now: now)?
        .phase,
      .online
    )

    var wrongCommit = snapshot
    wrongCommit.expectedCommitSHA = "different"
    XCTAssertNotEqual(
      ArticlePublishProgress.make(
        record: record, snapshot: wrongCommit, profile: profile, now: now)?.phase,
      .online
    )

    var wrongBranch = snapshot
    wrongBranch.expectedBranch = "release"
    XCTAssertNotEqual(
      ArticlePublishProgress.make(
        record: record, snapshot: wrongBranch, profile: profile, now: now)?.phase,
      .online
    )

    let wrongDigest = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .success, attribution: true, articleLevel: .success,
      digest: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    XCTAssertEqual(
      ArticlePublishProgress.make(
        record: record, snapshot: wrongDigest, profile: profile, now: now)?.phase,
      .verifyingArticle
    )
  }

  func testHTTPSuccessWithoutDigestCannotBecomeOnline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now)
    let snapshot = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .success, attribution: true, articleLevel: .success, digest: nil)

    let progress = ArticlePublishProgress.make(
      record: record, snapshot: snapshot, profile: profile, now: now)
    XCTAssertEqual(progress?.phase, .verifyingArticle)
    XCTAssertTrue(progress?.isPending == true)
  }

  func testMissingTargetDigestCannotBecomeOnline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now, sourceDigest: nil)
    let snapshot = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .success, attribution: true, articleLevel: .success, digest: nil)

    XCTAssertEqual(
      ArticlePublishProgress.make(record: record, snapshot: snapshot, profile: profile, now: now)?
        .phase,
      .verifyingArticle
    )
  }

  func testArticleNotFoundAfterSuccessfulPlatformRemainsPending() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now)
    let snapshot = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .success, attribution: true, articleLevel: .failed,
      digest: nil, message: "文章返回 404")

    let progress = ArticlePublishProgress.make(
      record: record, snapshot: snapshot, profile: profile, now: now)
    XCTAssertEqual(progress?.phase, .verifyingArticle)
    XCTAssertTrue(progress?.isPending == true)
  }

  func testPlatformFailureNeedsAttentionOnlyWithVerifiedAttribution() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now)
    let attributed = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .failed, attribution: true, articleLevel: .unknown, digest: nil,
      message: "部署失败")
    XCTAssertEqual(
      ArticlePublishProgress.make(record: record, snapshot: attributed, profile: profile, now: now)?
        .phase,
      .needsAttention
    )

    var unverified = attributed
    unverified.attributionVerified = nil
    XCTAssertEqual(
      ArticlePublishProgress.make(record: record, snapshot: unverified, profile: profile, now: now)?
        .phase,
      .waitingForDeployment
    )
  }

  func testSnapshotBeforeTrackingStartDoesNotSatisfyRequest() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now)
    let snapshot = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(-1),
      platform: .success, attribution: true, articleLevel: .success,
      digest: record.articleVerificationTargets[0].sourceDocumentDigest)

    XCTAssertEqual(
      ArticlePublishProgress.make(record: record, snapshot: snapshot, profile: profile, now: now)?
        .phase,
      .waitingForDeployment
    )
  }

  func testChangingOrRemovingSiteProfileCannotReuseTracking() {
    let now = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: now)
    let snapshot = makeSnapshot(
      record: record, profile: profile, checkedAt: now.addingTimeInterval(1),
      platform: .success, attribution: true, articleLevel: .success,
      digest: record.articleVerificationTargets[0].sourceDocumentDigest)
    var changed = profile
    changed.name = "Other site"
    changed.repoName = "other-repo"

    let progress = ArticlePublishProgress.make(
      record: record, snapshot: snapshot, profile: changed, now: now)
    XCTAssertEqual(progress?.phase, .needsAttention)
    XCTAssertTrue(progress?.message.contains("站点") == true)
    XCTAssertEqual(
      ArticlePublishProgress.make(record: record, snapshot: snapshot, profile: nil, now: now)?
        .phase, .needsAttention)
  }

  func testExpiredTrackingNeedsAttentionAndMissingConfigurationIsExplicit() {
    let startedAt = Date(timeIntervalSince1970: 10_000)
    let (profile, record) = fixture(now: startedAt)
    let expired = ArticlePublishProgress.make(
      record: record, snapshot: nil, profile: profile,
      now: startedAt.addingTimeInterval(ArticlePublishTrackingRequest.duration + 1))
    XCTAssertEqual(expired?.phase, .needsAttention)
    XCTAssertTrue(expired?.message.contains("自动跟踪已结束") == true)

    let missing = ArticlePublishProgress.make(
      record: record, snapshot: nil, profile: profile,
      unavailableReason: "未配置部署状态端点", now: startedAt)
    XCTAssertEqual(missing?.phase, .needsAttention)
    XCTAssertEqual(missing?.message, "未配置部署状态端点")
  }

  func testLegacyReleaseRecordDecodesWithoutTrackingAndNewRequestRoundTrips() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let (_, record) = fixture(now: now)
    let encoded = try JSONEncoder().encode(record)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "articlePublishTrackingRequest")
    let legacy = try JSONDecoder().decode(
      ReleaseRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.articlePublishTrackingRequest)

    let loaded = try JSONDecoder().decode(ReleaseRecord.self, from: encoded)
    XCTAssertEqual(loaded.articlePublishTrackingRequest, record.articlePublishTrackingRequest)
  }

  private func fixture(
    now: Date,
    sourceDigest: String? = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  ) -> (SiteProfile, ReleaseRecord) {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/"
    let item = ReleaseRecordBatchItem(
      draftID: UUID(), draftTitle: "Article", markdownPath: "content/posts/article.md",
      publicPath: "/article/", publicURLText: "https://example.com/article/",
      sourceDocumentDigest: sourceDigest, changedPaths: ["content/posts/article.md"])
    let request = ArticlePublishTrackingRequest(profile: profile, now: now)
    let record = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Article", summary: "Published", siteProfileID: profile.id,
      siteName: profile.name, branchName: profile.branch, targetBranch: profile.branch,
      commitSHA: "release-sha", batchItems: [item], articlePublishTrackingRequest: request,
      createdAt: now)
    return (profile, record)
  }

  private func makeSnapshot(
    record: ReleaseRecord, profile: SiteProfile, checkedAt: Date,
    platform: DeploymentStatusLevel, attribution: Bool,
    articleLevel: DeploymentStatusLevel, digest: String?, message: String = "ok"
  ) -> DeploymentStatusSnapshot {
    let target = record.articleVerificationTargets[0]
    let article = DeploymentArticleVerificationResult(
      target: target, checkedAt: checkedAt,
      signals: [
        DeploymentStatusSignal(
          level: articleLevel, title: "Article", message: message,
          verifiedSourceDocumentDigest: digest)
      ])
    return DeploymentStatusSnapshot(
      profileID: profile.id, releaseRecordID: record.id, provider: .custom,
      level: platform == .success ? .success : .failed, title: "Platform", message: message,
      siteURLText: profile.deploymentSiteURL, checkedAt: checkedAt, signals: [],
      expectedBranch: record.branchName, expectedCommitSHA: record.commitSHA,
      attributionVerified: attribution, platformLevel: platform, articleResults: [article])
  }
}
