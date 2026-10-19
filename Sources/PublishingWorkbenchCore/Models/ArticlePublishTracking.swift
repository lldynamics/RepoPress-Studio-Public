import Foundation

/// A single publish's read-only follow-up, saved atomically with its release.
/// The request stays unchanged while a check is in flight. Terminal evidence
/// is attached only after the release record's stale-response guard succeeds.
public struct ArticlePublishTrackingRequest: Codable, Hashable, Sendable {
  public static let duration: TimeInterval = 30 * 60
  public static let checkInterval: TimeInterval = 15

  public let startedAt: Date
  public let deadline: Date
  public let target: Target
  public var completedSnapshot: DeploymentStatusSnapshot?

  public init(profile: SiteProfile, now: Date = Date()) {
    startedAt = now
    deadline = now.addingTimeInterval(Self.duration)
    target = Target(profile: profile)
  }

  public struct Target: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let repository: DraftRepositoryIdentity
    public let provider: DeploymentProvider?
    public let siteURL: String?
    public let endpointURL: String?
    public let endpointUsesToken: Bool
    public let projectID: String?
    public let accountID: String?

    public init(profile: SiteProfile) {
      profileID = profile.id
      repository = DraftRepositoryIdentity(profile: profile)
      provider = profile.deploymentProvider
      siteURL = profile.deploymentSiteURL
      endpointURL = profile.deploymentStatusEndpointURL
      endpointUsesToken = profile.deploymentStatusEndpointUsesToken ?? false
      projectID = profile.deploymentProjectID
      accountID = profile.deploymentAccountID
    }
  }
}

/// Shared by the publish result and history. A successful push or HTTP 200
/// alone can never produce `online`.
public struct ArticlePublishProgress: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case waitingForDeployment
    case verifyingArticle
    case online
    case needsAttention
  }

  public let phase: Phase
  public let message: String

  public var isPending: Bool {
    phase == .waitingForDeployment || phase == .verifyingArticle
  }

  public var title: String {
    switch phase {
    case .waitingForDeployment: CoreL10n.text("正在等待网站部署")
    case .verifyingArticle: CoreL10n.text("正在核验文章版本")
    case .online: CoreL10n.text("已上线")
    case .needsAttention: CoreL10n.text("已推送，尚未确认上线")
    }
  }

  public static func make(
    record: ReleaseRecord, snapshot: DeploymentStatusSnapshot?, profile: SiteProfile?,
    unavailableReason: String? = nil, now: Date = Date()
  ) -> Self? {
    guard let request = record.articlePublishTrackingRequest else { return nil }
    guard let profile, profile.id == record.siteProfileID,
      request.target == ArticlePublishTrackingRequest.Target(profile: profile)
    else {
      return Self(
        phase: .needsAttention,
        message: CoreL10n.text("站点或发布目标已变化，请核对发布配置后重新检查。"))
    }
    let currentSnapshot = (request.completedSnapshot ?? snapshot).flatMap {
      $0.checkedAt >= request.startedAt && $0.checkedAt <= request.deadline
        && $0.matchesReleaseIdentity(record) ? $0 : nil
    }
    if let currentSnapshot, currentSnapshot.verifiesAllArticles(in: record),
      !record.articleVerificationTargets.isEmpty
    {
      return Self(
        phase: .online, message: CoreL10n.text("网站部署和这篇文章的源版本均已核验。"))
    }
    if let currentSnapshot, currentSnapshot.platformLevel == .success,
      currentSnapshot.attributionVerified == true,
      let diagnostic = currentSnapshot.articleResults?.lazy.flatMap({ $0.signals })
        .first(where: { isTerminalArticleVersionDiagnostic($0.diagnostic) })
    {
      return Self(
        phase: .needsAttention,
        message: CoreL10n.format("部署已完成，但需文章版本标记：%@", diagnostic.message))
    }
    if let currentSnapshot, currentSnapshot.platformLevel == .failed,
      currentSnapshot.attributionVerified == true
    {
      return Self(phase: .needsAttention, message: currentSnapshot.message)
    }
    guard now < request.deadline, request.deadline > request.startedAt,
      request.deadline.timeIntervalSince(request.startedAt)
        <= ArticlePublishTrackingRequest.duration
    else {
      return Self(
        phase: .needsAttention,
        message: CoreL10n.text("自动跟踪已结束，仍未确认本次文章版本上线。可重新检查，无需再次发布。"))
    }
    if currentSnapshot?.platformLevel == .success,
      currentSnapshot?.attributionVerified == true
    {
      if let unavailableReason {
        return Self(
          phase: .needsAttention,
          message: CoreL10n.format("部署已完成，但正文版本尚未确认。%@", unavailableReason))
      }
      return Self(
        phase: .verifyingArticle,
        message: CoreL10n.text("部署已完成，正在等待页面显示本次文章版本。可以继续写作。"))
    }
    if let unavailableReason {
      return Self(phase: .needsAttention, message: unavailableReason)
    }
    return Self(
      phase: .waitingForDeployment,
      message: CoreL10n.text("内容已推送，系统会继续检查部署和文章版本。可以继续写作。"))
  }

  private static func isTerminalArticleVersionDiagnostic(
    _ signal: DeploymentStatusSignalDiagnostic?
  ) -> Bool {
    switch signal {
    case .missingExpectedDigest, .missingMarker, .invalidMarker:
      return true
    case .digestMismatch, .none:
      return false
    }
  }
}

extension ReleaseRecord {
  /// A transient projection for deployment-status providers. It deliberately
  /// preserves the persisted Review record and its original head SHA.
  var deploymentAttributionRecord: ReleaseRecord {
    guard let deploymentCommitSHA, let deploymentBranchName else { return self }
    var projected = self
    projected.commitSHA = deploymentCommitSHA
    projected.branchName = deploymentBranchName
    return projected
  }
}
