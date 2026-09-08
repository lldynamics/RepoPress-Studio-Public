import Foundation

extension DeploymentStatusService {

  /// Verifies the newest GitHub Pages deployment for this exact release commit.
  /// It deliberately does not inspect Actions runs or a provider-supplied
  /// `statuses_url`: neither proves that the Pages deployment itself reached
  /// `success` for the article-bearing commit.
  func githubArticleDeploymentSignal(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String
  ) async -> DeploymentStatusSignal {
    guard let releaseRecord,
      let expectedCommit = releaseRecord.commitSHA?.trimmedForPublishing.nilIfEmpty,
      !token.trimmedForPublishing.isEmpty,
      hasRepositoryConfiguration(profile)
    else {
      return githubArticleDeploymentUnknown(
        profile: profile,
        releaseRecord: releaseRecord,
        message: CoreL10n.text("缺少当前发布提交或 GitHub 部署检查凭据，无法确认文章已上线。"),
        deploymentBranch: nil,
        deploymentCommit: nil
      )
    }

    let expectedBranch = expectedDeploymentBranch(releaseRecord: releaseRecord, profile: profile)
    do {
      let deployments: [GitHubArticleDeploymentResponse] = try await send(
        githubRequest(
          profile: profile,
          path:
            "/repos/\(encodedPathComponent(profile.repoOwner))/\(encodedPathComponent(profile.repoName))/deployments",
          token: token,
          queryItems: [
            URLQueryItem(name: "sha", value: expectedCommit),
            URLQueryItem(name: "environment", value: "github-pages"),
            URLQueryItem(name: "per_page", value: "1"),
          ]
        )
      )
      guard let deployment = deployments.first else {
        return githubArticleDeploymentUnknown(
          profile: profile,
          releaseRecord: releaseRecord,
          message: CoreL10n.text("没有找到当前提交的 GitHub Pages 部署。"),
          deploymentBranch: nil,
          deploymentCommit: nil
        )
      }
      guard let deploymentID = deployment.id, deploymentID > 0,
        let deploymentCommit = deployment.sha?.trimmedForPublishing.nilIfEmpty,
        let deploymentRef = deployment.ref?.trimmedForPublishing.nilIfEmpty,
        deployment.environment == "github-pages",
        deployment.transientEnvironment == false
      else {
        return githubArticleDeploymentUnknown(
          profile: profile,
          releaseRecord: releaseRecord,
          message: CoreL10n.text("最新 GitHub Pages 部署缺少可验证的提交、环境或持久化标记。"),
          deploymentBranch: deployment.ref,
          deploymentCommit: deployment.sha
        )
      }
      guard githubDeploymentSHAEquals(deploymentCommit, expectedCommit) else {
        return githubArticleDeploymentUnknown(
          profile: profile,
          releaseRecord: releaseRecord,
          message: CoreL10n.text("最新 GitHub Pages 部署的提交与本次发布不一致。"),
          deploymentBranch: deploymentRef,
          deploymentCommit: deploymentCommit
        )
      }
      guard
        (expectedBranch.map { deploymentRef == $0 } ?? false)
          || githubDeploymentSHAEquals(deploymentRef, expectedCommit)
      else {
        return githubArticleDeploymentUnknown(
          profile: profile,
          releaseRecord: releaseRecord,
          message: CoreL10n.text("最新 GitHub Pages 部署的 ref 不属于本次发布分支或提交。"),
          deploymentBranch: deploymentRef,
          deploymentCommit: deploymentCommit
        )
      }

      let statuses: [GitHubArticleDeploymentStatusResponse] = try await send(
        githubRequest(
          profile: profile,
          path:
            "/repos/\(encodedPathComponent(profile.repoOwner))/\(encodedPathComponent(profile.repoName))/deployments/\(deploymentID)/statuses",
          token: token,
          queryItems: [URLQueryItem(name: "per_page", value: "1")]
        )
      )
      guard let status = statuses.first,
        let state = status.state?.trimmedForPublishing.nilIfEmpty?.lowercased()
      else {
        return githubArticleDeploymentUnknown(
          profile: profile,
          releaseRecord: releaseRecord,
          message: CoreL10n.text("最新 GitHub Pages 部署没有可验证的状态。"),
          deploymentBranch: deploymentRef,
          deploymentCommit: deploymentCommit
        )
      }

      return githubArticleDeploymentStatusSignal(
        state: state,
        profile: profile,
        releaseRecord: releaseRecord,
        deploymentBranch: deploymentRef,
        deploymentCommit: deploymentCommit
      )
    } catch {
      return githubArticleDeploymentUnknown(
        profile: profile,
        releaseRecord: releaseRecord,
        message: CoreL10n.text("读取 GitHub Pages 部署状态失败，无法确认文章已上线。"),
        deploymentBranch: nil,
        deploymentCommit: nil
      )
    }
  }

  private func githubArticleDeploymentStatusSignal(
    state: String,
    profile: SiteProfile,
    releaseRecord: ReleaseRecord,
    deploymentBranch: String,
    deploymentCommit: String
  ) -> DeploymentStatusSignal {
    let level: DeploymentStatusLevel
    let verified: Bool
    switch state {
    case "success":
      level = .success
      verified = true
    case "error", "failure", "failed":
      level = .failed
      verified = true
    case "pending", "in_progress", "queued":
      level = .running
      verified = true
    default:
      level = .unknown
      verified = false
    }
    return DeploymentStatusSignal(
      level: level,
      title: "GitHub Pages Deployment",
      message: CoreL10n.format("GitHub Pages 部署状态：%@", state),
      expectedBranch: expectedDeploymentBranch(releaseRecord: releaseRecord, profile: profile),
      expectedCommitSHA: releaseRecord.commitSHA?.trimmedForPublishing.nilIfEmpty,
      observedBranch: deploymentBranch,
      observedCommitSHA: deploymentCommit,
      attributionVerified: verified
    )
  }

  private func githubArticleDeploymentUnknown(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    message: String,
    deploymentBranch: String?,
    deploymentCommit: String?
  ) -> DeploymentStatusSignal {
    var signal = deploymentAttributionSignal(
      provider: .githubPages,
      message: message,
      urlText: nil,
      deploymentBranch: deploymentBranch,
      deploymentCommit: deploymentCommit,
      releaseRecord: releaseRecord,
      profile: profile,
      verified: false
    )
    signal.level = .unknown
    signal.title = "GitHub Pages Deployment"
    signal.attributionVerified = false
    return signal
  }

  private func githubDeploymentSHAEquals(_ lhs: String, _ rhs: String) -> Bool {
    lhs.caseInsensitiveCompare(rhs) == .orderedSame
  }
}

private struct GitHubArticleDeploymentResponse: Decodable {
  let id: Int64?
  let sha: String?
  let ref: String?
  let environment: String?
  let transientEnvironment: Bool?

  private enum CodingKeys: String, CodingKey {
    case id
    case sha
    case ref
    case environment
    case transientEnvironment = "transient_environment"
  }
}

private struct GitHubArticleDeploymentStatusResponse: Decodable {
  let state: String?
}
