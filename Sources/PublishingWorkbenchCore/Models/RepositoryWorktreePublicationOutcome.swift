import Foundation
import PublishingCoreSupport

public struct RepositoryWorktreePublicationOutcome: Hashable, Sendable {
  public let feedback: PublishActionFeedback
  public let deploymentVerified: Bool
  public let articleVerified: Bool

  public init(
    feedback: PublishActionFeedback,
    deploymentVerified: Bool,
    articleVerified: Bool
  ) {
    self.feedback = feedback
    self.deploymentVerified = deploymentVerified
    self.articleVerified = articleVerified
  }

  public static func evaluate(
    result: RepositoryWorktreePublishResult,
    articleTarget: RepositoryWorktreeArticleVerificationTarget?,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> RepositoryWorktreePublicationOutcome {
    let commit = String(result.commitSHA.prefix(8))
    let pushed = CoreL10n.format("Git 推送已确认（%@ · %@）", result.branch, commit)
    guard let deploymentStatus else {
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format("%@；部署尚未验证，不能判定网站发布成功。", pushed),
          status: .warning
        ),
        deploymentVerified: false,
        articleVerified: false
      )
    }

    switch deploymentStatus.level {
    case .running:
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format("%@；部署仍在进行，文章尚未确认上线。", pushed),
          status: .inProgress
        ),
        deploymentVerified: false,
        articleVerified: false
      )
    case .failed:
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format("%@；部署或线上页面检查失败，网站发布未完成。", pushed),
          status: .failure
        ),
        deploymentVerified: false,
        articleVerified: false
      )
    case .unknown:
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format("%@；部署状态未知，不能判定网站发布成功。", pushed),
          status: .warning
        ),
        deploymentVerified: false,
        articleVerified: false
      )
    case .success:
      break
    }

    guard deploymentStatus.attributionVerified == true else {
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format("%@；部署端点可达，但没有绑定当前 commit 的证据。", pushed),
          status: .warning
        ),
        deploymentVerified: false,
        articleVerified: false
      )
    }

    guard articleTarget != nil else {
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format(
            "%@；部署已验证，但本次没有可冻结的文章目标，未验证具体文章页面。",
            pushed
          ),
          status: .information
        ),
        deploymentVerified: true,
        articleVerified: false
      )
    }

    let contentLevel = deploymentStatus.signals.first {
      $0.title == CoreL10n.text("发布页面内容")
    }?.level
    let seoLevel = deploymentStatus.signals.first {
      $0.title == CoreL10n.text("发布页面 SEO")
    }?.level
    if contentLevel == .success, seoLevel == .success {
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format(
            "%@；部署、文章内容与 canonical/og:url 已验证，文章发布成功。",
            pushed
          ),
          status: .success
        ),
        deploymentVerified: true,
        articleVerified: true
      )
    }
    if contentLevel == .failed || seoLevel == .failed {
      return RepositoryWorktreePublicationOutcome(
        feedback: PublishActionFeedback(
          message: CoreL10n.format(
            "%@；部署已完成，但文章内容或 canonical/og:url 验证失败。",
            pushed
          ),
          status: .failure
        ),
        deploymentVerified: true,
        articleVerified: false
      )
    }
    return RepositoryWorktreePublicationOutcome(
      feedback: PublishActionFeedback(
        message: CoreL10n.format(
          "%@；部署已验证，但文章页面证据不完整，不能判定文章发布成功。",
          pushed
        ),
        status: .warning
      ),
      deploymentVerified: true,
      articleVerified: false
    )
  }

  public static func verificationIsComplete(
    articleTarget: RepositoryWorktreeArticleVerificationTarget?,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> Bool {
    guard let deploymentStatus,
      deploymentStatus.level == .success,
      deploymentStatus.attributionVerified == true
    else { return false }
    guard articleTarget != nil else { return true }
    return deploymentStatus.signals.contains {
      $0.title == CoreL10n.text("发布页面内容") && $0.level == .success
    }
      && deploymentStatus.signals.contains {
        $0.title == CoreL10n.text("发布页面 SEO") && $0.level == .success
      }
  }
}
