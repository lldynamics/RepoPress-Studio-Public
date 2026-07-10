import Foundation

extension DeploymentStatusService {

  func githubSignals(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String?
  ) async -> [DeploymentStatusSignal] {
    guard hasRepositoryConfiguration(profile) else {
      return [
        DeploymentStatusSignal(level: .unknown, title: "GitHub 仓库未配置", message: "缺少 owner 或 repository。")
      ]
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(level: .unknown, title: "GitHub API 未检查", message: "缺少部署 Token，只能检查站点 URL。")
      ]
    }

    let pages = await githubPagesSignal(profile: profile, token: token)
    let actions = await githubActionsSignal(profile: profile, releaseRecord: releaseRecord, token: token)
    return [pages, actions]
  }

  func gitLabSignals(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String?
  ) async -> [DeploymentStatusSignal] {
    guard hasRepositoryConfiguration(profile) else {
      return [
        DeploymentStatusSignal(level: .unknown, title: "GitLab 项目未配置", message: "缺少 namespace 或 project。")
      ]
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(level: .unknown, title: "GitLab API 未检查", message: "缺少部署 Token，只能检查站点 URL。")
      ]
    }

    return [await gitLabPipelineSignal(profile: profile, releaseRecord: releaseRecord, token: token)]
  }

  func netlifySignals(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String?
  ) async -> [DeploymentStatusSignal] {
    guard let siteID = profile.deploymentProjectID?.trimmedForPublishing.nilIfEmpty else {
      return []
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(
          level: .unknown,
          title: "Netlify API 未检查",
          message: "已配置 Netlify Site ID，但缺少部署 Token；只能检查站点 URL 或状态端点。"
        )
      ]
    }

    return [await netlifyDeploySignal(siteID: siteID, profile: profile, releaseRecord: releaseRecord, token: token)]
  }

  func vercelSignals(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String?
  ) async -> [DeploymentStatusSignal] {
    guard let projectID = profile.deploymentProjectID?.trimmedForPublishing.nilIfEmpty else {
      return []
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(
          level: .unknown,
          title: "Vercel API 未检查",
          message: "已配置 Vercel Project ID，但缺少部署 Token；只能检查站点 URL 或状态端点。"
        )
      ]
    }

    return [await vercelDeploymentSignal(profile: profile, projectID: projectID, releaseRecord: releaseRecord, token: token)]
  }

  func cloudflarePagesSignals(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String?
  ) async -> [DeploymentStatusSignal] {
    guard let accountID = profile.deploymentAccountID?.trimmedForPublishing.nilIfEmpty,
          let projectName = profile.deploymentProjectID?.trimmedForPublishing.nilIfEmpty else {
      return []
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(
          level: .unknown,
          title: "Cloudflare Pages API 未检查",
          message: "已配置 Cloudflare Account ID 和项目名，但缺少部署 Token；只能检查站点 URL 或状态端点。"
        )
      ]
    }

    return [
      await cloudflarePagesDeploymentSignal(
        accountID: accountID,
        projectName: projectName,
        profile: profile,
        releaseRecord: releaseRecord,
        token: token
      )
    ]
  }

  func githubPagesSignal(profile: SiteProfile, token: String) async -> DeploymentStatusSignal {
    do {
      let response: GitHubPagesStatusResponse = try await send(
        githubRequest(
          profile: profile,
          path: "/repos/\(encodedPathComponent(profile.repoOwner))/\(encodedPathComponent(profile.repoName))/pages",
          token: token
        )
      )
      return DeploymentStatusSignal(
        level: githubPagesLevel(response.status),
        title: "GitHub Pages",
        message: response.status?.nilIfEmpty.map { "Pages 状态：\($0)" } ?? "已读取 Pages 状态。",
        urlText: response.htmlURL
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "GitHub Pages",
        message: "读取 Pages 状态失败：\(error.localizedDescription)"
      )
    }
  }

  func githubActionsSignal(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String
  ) async -> DeploymentStatusSignal {
    do {
      var queryItems = [
        URLQueryItem(name: "branch", value: releaseRecord?.branchName ?? profile.branch.nilIfEmpty ?? "main"),
        URLQueryItem(name: "per_page", value: "1"),
      ]
      if let commitSHA = releaseRecord?.commitSHA?.nilIfEmpty {
        queryItems.append(URLQueryItem(name: "head_sha", value: commitSHA))
      }
      let response: GitHubActionsRunsResponse = try await send(
        githubRequest(
          profile: profile,
          path: "/repos/\(encodedPathComponent(profile.repoOwner))/\(encodedPathComponent(profile.repoName))/actions/runs",
          token: token,
          queryItems: queryItems
        )
      )
      guard let run = response.workflowRuns.first else {
        return DeploymentStatusSignal(level: .unknown, title: "GitHub Actions", message: "没有找到最近的 Actions 运行记录。")
      }
      return DeploymentStatusSignal(
        level: githubActionLevel(status: run.status, conclusion: run.conclusion),
        title: run.name?.nilIfEmpty ?? "GitHub Actions",
        message: [run.status, run.conclusion].compactMap { $0?.nilIfEmpty }.joined(separator: " / "),
        urlText: run.htmlURL
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "GitHub Actions",
        message: "读取 Actions 状态失败：\(error.localizedDescription)"
      )
    }
  }

  func gitLabPipelineSignal(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String
  ) async -> DeploymentStatusSignal {
    do {
      let response: [GitLabPipelineStatusResponse] = try await send(
        gitLabRequest(
          profile: profile,
          path: "/projects/\(encodedPathComponent(profile.repoOwner + "/" + profile.repoName))/pipelines",
          token: token,
          queryItems: [
            URLQueryItem(name: "ref", value: releaseRecord?.branchName ?? profile.branch.nilIfEmpty ?? "main"),
            URLQueryItem(name: "per_page", value: "1"),
          ]
        )
      )
      guard let pipeline = response.first else {
        return DeploymentStatusSignal(level: .unknown, title: "GitLab Pipeline", message: "没有找到最近的 Pipeline。")
      }
      return DeploymentStatusSignal(
        level: gitLabPipelineLevel(pipeline.status),
        title: "GitLab Pipeline",
        message: pipeline.status?.nilIfEmpty.map { "Pipeline 状态：\($0)" } ?? "已读取 Pipeline 状态。",
        urlText: pipeline.webURL
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "GitLab Pipeline",
        message: "读取 Pipeline 状态失败：\(error.localizedDescription)"
      )
    }
  }

  func netlifyDeploySignal(
    siteID: String,
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String
  ) async -> DeploymentStatusSignal {
    do {
      let response: [NetlifyDeployStatusResponse] = try await send(
        netlifyRequest(
          path: "/api/v1/sites/\(encodedPathComponent(siteID))/deploys",
          token: token,
          queryItems: [URLQueryItem(name: "per_page", value: "1")]
        )
      )
      guard let deploy = response.first else {
        return DeploymentStatusSignal(level: .unknown, title: "Netlify Deploy", message: "没有找到最近的部署记录。")
      }

      let title = deploy.name?.nilIfEmpty ?? deploy.title?.nilIfEmpty ?? "Netlify Deploy"
      let messageParts = [
        deploy.state?.nilIfEmpty.map { "状态：\($0)" },
        deploy.branch?.nilIfEmpty.map { "分支：\($0)" },
        deploy.commitRef?.nilIfEmpty.map { "提交：\($0)" },
        deploy.errorMessage?.nilIfEmpty
      ].compactMap { $0 }
      let urlText = deploy.adminURL?.nilIfEmpty ?? deploy.deployURL?.nilIfEmpty ?? deploy.url?.nilIfEmpty
      if let mismatch = releaseAttributionMismatchMessage(
        provider: .netlify,
        deploymentBranch: deploy.branch,
        deploymentCommit: deploy.commitRef,
        releaseRecord: releaseRecord,
        profile: profile
      ) {
        return DeploymentStatusSignal(
          level: .unknown,
          title: title,
          message: mismatch,
          urlText: urlText
        )
      }
      return DeploymentStatusSignal(
        level: netlifyDeployLevel(deploy.state),
        title: title,
        message: messageParts.isEmpty ? "已读取最近一次 Netlify 部署。" : messageParts.joined(separator: " · "),
        urlText: urlText
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "Netlify Deploy",
        message: "读取 Netlify 部署状态失败：\(error.localizedDescription)"
      )
    }
  }

  func vercelDeploymentSignal(
    profile: SiteProfile,
    projectID: String,
    releaseRecord: ReleaseRecord?,
    token: String
  ) async -> DeploymentStatusSignal {
    do {
      var queryItems = [
        URLQueryItem(name: "projectId", value: projectID),
        URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "target", value: "production"),
      ]
      if let teamID = profile.deploymentAccountID?.trimmedForPublishing.nilIfEmpty {
        queryItems.append(URLQueryItem(name: "teamId", value: teamID))
      }
      if let commitSHA = releaseRecord?.commitSHA?.nilIfEmpty {
        queryItems.append(URLQueryItem(name: "sha", value: commitSHA))
      }
      if let branch = releaseRecord?.branchName?.nilIfEmpty ?? profile.branch.nilIfEmpty {
        queryItems.append(URLQueryItem(name: "branch", value: branch))
      }

      let response: VercelDeploymentsResponse = try await send(
        vercelRequest(path: "/v7/deployments", token: token, queryItems: queryItems)
      )
      guard let deployment = response.deployments.first else {
        return DeploymentStatusSignal(level: .unknown, title: "Vercel Deployment", message: "没有找到最近的部署记录。")
      }

      let status = deployment.readyState?.nilIfEmpty ?? deployment.state?.nilIfEmpty
      let messageParts = [
        status.map { "状态：\($0)" },
        deployment.target?.nilIfEmpty.map { "目标：\($0)" },
        deployment.meta?.branch?.nilIfEmpty.map { "分支：\($0)" },
        deployment.meta?.commitSHA?.nilIfEmpty.map { "提交：\($0)" },
        deployment.errorMessage?.nilIfEmpty
      ].compactMap { $0 }
      let urlText = deployment.inspectorURL?.nilIfEmpty ?? normalizedURLText(deployment.url)
      if let mismatch = releaseAttributionMismatchMessage(
        provider: .vercel,
        deploymentBranch: deployment.meta?.branch,
        deploymentCommit: deployment.meta?.commitSHA,
        releaseRecord: releaseRecord,
        profile: profile
      ) {
        return DeploymentStatusSignal(
          level: .unknown,
          title: deployment.name?.nilIfEmpty ?? "Vercel Deployment",
          message: mismatch,
          urlText: urlText
        )
      }
      return DeploymentStatusSignal(
        level: vercelDeploymentLevel(status),
        title: deployment.name?.nilIfEmpty ?? "Vercel Deployment",
        message: messageParts.isEmpty ? "已读取最近一次 Vercel 部署。" : messageParts.joined(separator: " · "),
        urlText: urlText
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "Vercel Deployment",
        message: "读取 Vercel 部署状态失败：\(error.localizedDescription)"
      )
    }
  }

  func cloudflarePagesDeploymentSignal(
    accountID: String,
    projectName: String,
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String
  ) async -> DeploymentStatusSignal {
    do {
      let response: CloudflarePagesDeploymentsResponse = try await send(
        cloudflareRequest(
          path: "/client/v4/accounts/\(encodedPathComponent(accountID))/pages/projects/\(encodedPathComponent(projectName))/deployments",
          token: token,
          queryItems: [
            URLQueryItem(name: "env", value: "production"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: "1"),
          ]
        )
      )
      guard let deployment = response.result.first else {
        return DeploymentStatusSignal(level: .unknown, title: "Cloudflare Pages", message: "没有找到最近的 Pages 部署记录。")
      }

      let status = deployment.latestStage?.status?.nilIfEmpty
      let trigger = deployment.deploymentTrigger?.metadata
      let messageParts = [
        status.map { "状态：\($0)" },
        trigger?.branch?.nilIfEmpty.map { "分支：\($0)" },
        trigger?.commitHash?.nilIfEmpty.map { "提交：\($0)" },
        trigger?.commitMessage?.nilIfEmpty
      ].compactMap { $0 }
      let urlText = deployment.url?.nilIfEmpty ?? deployment.aliases.first?.nilIfEmpty
      if let mismatch = releaseAttributionMismatchMessage(
        provider: .cloudflarePages,
        deploymentBranch: trigger?.branch,
        deploymentCommit: trigger?.commitHash,
        releaseRecord: releaseRecord,
        profile: profile
      ) {
        return DeploymentStatusSignal(
          level: .unknown,
          title: deployment.latestStage?.name?.nilIfEmpty ?? "Cloudflare Pages",
          message: mismatch,
          urlText: urlText
        )
      }
      return DeploymentStatusSignal(
        level: cloudflarePagesDeploymentLevel(status),
        title: deployment.latestStage?.name?.nilIfEmpty ?? "Cloudflare Pages",
        message: messageParts.isEmpty ? "已读取最近一次 Cloudflare Pages 部署。" : messageParts.joined(separator: " · "),
        urlText: urlText
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "Cloudflare Pages",
        message: "读取 Cloudflare Pages 部署状态失败：\(error.localizedDescription)"
      )
    }
  }
  func releaseAttributionMismatchMessage(
    provider: DeploymentProvider,
    deploymentBranch: String?,
    deploymentCommit: String?,
    releaseRecord: ReleaseRecord?,
    profile: SiteProfile
  ) -> String? {
    guard let releaseRecord else {
      return nil
    }
    let expectedBranch = releaseRecord.branchName?.trimmedForPublishing.nilIfEmpty
      ?? profile.branch.trimmedForPublishing.nilIfEmpty
    let expectedCommit = releaseRecord.commitSHA?.trimmedForPublishing.nilIfEmpty
    let actualBranch = deploymentBranch?.trimmedForPublishing.nilIfEmpty
    let actualCommit = deploymentCommit?.trimmedForPublishing.nilIfEmpty
    var mismatches: [String] = []

    if let expectedCommit, let actualCommit, !commitMatches(actualCommit, expectedCommit) {
      mismatches.append("期望提交 \(shortCommit(expectedCommit))，实际 \(shortCommit(actualCommit))")
    }
    if let expectedBranch, let actualBranch,
       actualBranch.compare(expectedBranch, options: [.caseInsensitive]) != .orderedSame {
      mismatches.append("期望分支 \(expectedBranch)，实际 \(actualBranch)")
    }

    guard !mismatches.isEmpty else {
      return nil
    }
    return "最近一次 \(provider.displayName) 部署不是当前发布：\(mismatches.joined(separator: "；"))。请等待目标 commit 部署完成或检查部署队列。"
  }

  func commitMatches(_ actual: String, _ expected: String) -> Bool {
    let actualCommit = actual.lowercased()
    let expectedCommit = expected.lowercased()
    if actualCommit == expectedCommit {
      return true
    }
    let shortestCount = min(actualCommit.count, expectedCommit.count)
    guard shortestCount >= 7 else {
      return false
    }
    return actualCommit.hasPrefix(expectedCommit) || expectedCommit.hasPrefix(actualCommit)
  }

  func shortCommit(_ value: String) -> String {
    String(value.prefix(12))
  }
  func githubPagesLevel(_ status: String?) -> DeploymentStatusLevel {
    switch status?.lowercased() {
    case "built":
      return .success
    case "building", "queued":
      return .running
    case "errored":
      return .failed
    default:
      return .unknown
    }
  }

  func githubActionLevel(status: String?, conclusion: String?) -> DeploymentStatusLevel {
    switch status?.lowercased() {
    case "completed":
      return conclusion?.lowercased() == "success" ? .success : .failed
    case "queued", "in_progress", "requested", "waiting", "pending":
      return .running
    default:
      return .unknown
    }
  }

  func gitLabPipelineLevel(_ status: String?) -> DeploymentStatusLevel {
    switch status?.lowercased() {
    case "success":
      return .success
    case "created", "waiting_for_resource", "preparing", "pending", "running":
      return .running
    case "failed", "canceled", "skipped":
      return .failed
    default:
      return .unknown
    }
  }

  func netlifyDeployLevel(_ state: String?) -> DeploymentStatusLevel {
    switch state?.lowercased() {
    case "ready", "current", "uploaded":
      return .success
    case "new", "pending_review", "accepted", "enqueued", "building", "uploading", "retrying":
      return .running
    case "error", "failed", "canceled", "cancelled":
      return .failed
    default:
      return .unknown
    }
  }

  func vercelDeploymentLevel(_ state: String?) -> DeploymentStatusLevel {
    switch state?.lowercased() {
    case "ready":
      return .success
    case "queued", "building", "initializing", "analyzing", "deploying", "pending":
      return .running
    case "error", "canceled", "cancelled":
      return .failed
    default:
      return .unknown
    }
  }

  func cloudflarePagesDeploymentLevel(_ status: String?) -> DeploymentStatusLevel {
    switch status?.lowercased() {
    case "success", "succeeded", "complete", "completed":
      return .success
    case "queued", "running", "active", "building", "deploying", "waiting":
      return .running
    case "failure", "failed", "error", "canceled", "cancelled":
      return .failed
    default:
      return .unknown
    }
  }

}
