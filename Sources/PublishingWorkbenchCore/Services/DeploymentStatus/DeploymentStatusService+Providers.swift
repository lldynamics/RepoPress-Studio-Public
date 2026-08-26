import Foundation

extension DeploymentStatusService {

  func githubSignals(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    token: String?
  ) async -> [DeploymentStatusSignal] {
    guard hasRepositoryConfiguration(profile) else {
      return [
        DeploymentStatusSignal(
          level: .unknown,
          title: CoreL10n.text("GitHub 仓库未配置"),
          message: CoreL10n.text("缺少 owner 或 repository。")
        )
      ]
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(
          level: .unknown,
          title: CoreL10n.text("GitHub API 未检查"),
          message: CoreL10n.text("缺少部署 Token，只能检查站点 URL。")
        )
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
        DeploymentStatusSignal(
          level: .unknown,
          title: CoreL10n.text("GitLab 项目未配置"),
          message: CoreL10n.text("缺少 namespace 或 project。")
        )
      ]
    }
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      return [
        DeploymentStatusSignal(
          level: .unknown,
          title: CoreL10n.text("GitLab API 未检查"),
          message: CoreL10n.text("缺少部署 Token，只能检查站点 URL。")
        )
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
          title: CoreL10n.text("Netlify API 未检查"),
          message: CoreL10n.text("已配置 Netlify Site ID，但缺少部署 Token；只能检查站点 URL 或状态端点。")
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
          title: CoreL10n.text("Vercel API 未检查"),
          message: CoreL10n.text("已配置 Vercel Project ID，但缺少部署 Token；只能检查站点 URL 或状态端点。")
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
          title: CoreL10n.text("Cloudflare Pages API 未检查"),
          message: CoreL10n.text("已配置 Cloudflare Account ID 和项目名，但缺少部署 Token；只能检查站点 URL 或状态端点。")
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
        message: response.status?.nilIfEmpty.map { CoreL10n.format("Pages 状态：%@", $0) }
          ?? CoreL10n.text("已读取 Pages 状态。"),
        urlText: response.htmlURL
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "GitHub Pages",
        message: CoreL10n.format("读取 Pages 状态失败：%@", error.localizedDescription)
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
        return DeploymentStatusSignal(
          level: .unknown,
          title: "GitHub Actions",
          message: CoreL10n.text("没有找到最近的 Actions 运行记录。")
        )
      }
      let logExcerpt = await githubActionLogExcerpt(
        profile: profile,
        token: token,
        run: run
      )
      return DeploymentStatusSignal(
        level: githubActionLevel(status: run.status, conclusion: run.conclusion),
        title: run.name?.nilIfEmpty ?? "GitHub Actions",
        message: [run.status, run.conclusion].compactMap { $0?.nilIfEmpty }.joined(separator: " / "),
        urlText: run.htmlURL,
        logExcerpt: logExcerpt
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "GitHub Actions",
        message: CoreL10n.format("读取 Actions 状态失败：%@", error.localizedDescription)
      )
    }
  }

  /// Fetches the structured job/annotation details for a matching workflow
  /// run. Every log request is best-effort so a provider log outage cannot
  /// replace the already-known Actions status.
  func githubActionLogExcerpt(
    profile: SiteProfile,
    token: String,
    run: GitHubActionRunStatusResponse
  ) async -> [DeploymentLogEntry] {
    guard let runID = run.id else {
      return []
    }

    let jobs: GitHubActionsJobsResponse
    do {
      jobs = try await send(
        githubRequest(
          profile: profile,
          path: "/repos/\(encodedPathComponent(profile.repoOwner))/\(encodedPathComponent(profile.repoName))/actions/runs/\(runID)/jobs",
          token: token,
          queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )
      )
    } catch {
      return []
    }

    var entries: [DeploymentLogEntry] = []
    for job in jobs.jobs {
      let jobName = job.name?.nilIfEmpty ?? "GitHub Actions Job"
      if let steps = job.steps {
        for step in steps {
          let conclusion = step.conclusion?.nilIfEmpty ?? step.status?.nilIfEmpty
          guard let conclusion,
                conclusion.lowercased() != "success",
                conclusion.lowercased() != "completed" else {
            continue
          }
          let stepName = step.name?.nilIfEmpty ?? "未知步骤"
          if let entry = DeploymentLogExcerptPolicy.entry(
            level: githubLogLevel(conclusion: conclusion),
            source: "GitHub Actions · \(jobName)",
            message: "步骤 \(stepName)：\(conclusion)",
            stepName: stepName
          ) {
            entries.append(entry)
          }
        }
      }

      guard githubJobNeedsAnnotations(job),
            let checkRunID = githubCheckRunID(from: job.checkRunURL) else {
        continue
      }
      do {
        let annotations: [GitHubCheckRunAnnotationResponse] = try await send(
          githubRequest(
            profile: profile,
            path: "/repos/\(encodedPathComponent(profile.repoOwner))/\(encodedPathComponent(profile.repoName))/check-runs/\(checkRunID)/annotations",
            token: token,
            queryItems: [URLQueryItem(name: "per_page", value: "50")]
          )
        )
        entries.append(contentsOf: annotations.compactMap(githubLogEntry))
      } catch {
        // Keep job-step evidence even when the optional annotations endpoint
        // is unavailable or is not enabled for this token.
      }
    }
    return DeploymentLogExcerptPolicy.boundedEntries(entries)
  }

  func githubJobNeedsAnnotations(_ job: GitHubActionJobStatusResponse) -> Bool {
    switch job.conclusion?.lowercased() {
    case "failure", "failed", "timed_out", "cancelled":
      return true
    default:
      return false
    }
  }

  func githubCheckRunID(from urlText: String?) -> String? {
    guard let urlText = urlText?.trimmedForPublishing.nilIfEmpty,
          let url = URL(string: urlText) else {
      return nil
    }
    let components = url.pathComponents
    guard let index = components.lastIndex(of: "check-runs"),
          components.indices.contains(index + 1) else {
      return nil
    }
    let value = components[index + 1]
    guard value.allSatisfy(\.isNumber) else {
      return nil
    }
    return value
  }

  func githubLogLevel(conclusion: String) -> DeploymentLogLevel {
    switch conclusion.lowercased() {
    case "cancelled", "skipped", "neutral":
      return .warning
    default:
      return .error
    }
  }

  func githubLogEntry(_ annotation: GitHubCheckRunAnnotationResponse) -> DeploymentLogEntry? {
    let message = annotation.message?.nilIfEmpty ?? annotation.rawDetails?.nilIfEmpty ?? annotation.title
    guard let message else {
      return nil
    }
    let level: DeploymentLogLevel
    switch annotation.annotationLevel?.lowercased() {
    case "warning":
      level = .warning
    case "notice":
      level = .info
    default:
      level = .error
    }
    return DeploymentLogExcerptPolicy.entry(
      level: level,
      source: "GitHub Actions · Check annotation",
      message: message,
      filePath: annotation.path,
      line: annotation.startLine ?? annotation.endLine,
      column: annotation.startColumn ?? annotation.endColumn,
      stepName: annotation.title
    )
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
        return DeploymentStatusSignal(
          level: .unknown,
          title: "GitLab Pipeline",
          message: CoreL10n.text("没有找到最近的 Pipeline。")
        )
      }
      return DeploymentStatusSignal(
        level: gitLabPipelineLevel(pipeline.status),
        title: "GitLab Pipeline",
        message: pipeline.status?.nilIfEmpty.map { CoreL10n.format("Pipeline 状态：%@", $0) }
          ?? CoreL10n.text("已读取 Pipeline 状态。"),
        urlText: pipeline.webURL
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "GitLab Pipeline",
        message: CoreL10n.format("读取 Pipeline 状态失败：%@", error.localizedDescription)
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
        return DeploymentStatusSignal(
          level: .unknown,
          title: "Netlify Deploy",
          message: CoreL10n.text("没有找到最近的部署记录。")
        )
      }

      let title = deploy.name?.nilIfEmpty ?? deploy.title?.nilIfEmpty ?? "Netlify Deploy"
      let messageParts = [
        deploy.state?.nilIfEmpty.map { CoreL10n.format("状态：%@", $0) },
        deploy.branch?.nilIfEmpty.map { CoreL10n.format("分支：%@", $0) },
        deploy.commitRef?.nilIfEmpty.map { CoreL10n.format("提交：%@", $0) },
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
        message: messageParts.isEmpty
          ? CoreL10n.text("已读取最近一次 Netlify 部署。")
          : messageParts.joined(separator: " · "),
        urlText: urlText
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "Netlify Deploy",
        message: CoreL10n.format("读取 Netlify 部署状态失败：%@", error.localizedDescription)
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
      let targetEnvironment = releaseRecord.map { record in
        let releaseBranch = record.branchName?.nilIfEmpty
        let targetBranch = record.targetBranch?.nilIfEmpty ?? profile.branch.nilIfEmpty
        return releaseBranch != nil && releaseBranch != targetBranch
          ? "preview"
          : "production"
      } ?? "production"
      var queryItems = [
        URLQueryItem(name: "projectId", value: projectID),
        URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "target", value: targetEnvironment),
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
        return DeploymentStatusSignal(
          level: .unknown,
          title: "Vercel Deployment",
          message: CoreL10n.text("没有找到最近的部署记录。")
        )
      }

      let status = deployment.readyState?.nilIfEmpty ?? deployment.state?.nilIfEmpty
      let messageParts = [
        status.map { CoreL10n.format("状态：%@", $0) },
        deployment.target?.nilIfEmpty.map { CoreL10n.format("目标：%@", $0) },
        deployment.meta?.branch?.nilIfEmpty.map { CoreL10n.format("分支：%@", $0) },
        deployment.meta?.commitSHA?.nilIfEmpty.map { CoreL10n.format("提交：%@", $0) },
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
      let level = vercelDeploymentLevel(status)
      let logExcerpt: [DeploymentLogEntry]
      if level == .failed || level == .running,
         let deploymentID = deployment.deploymentIdentifier {
        logExcerpt = await vercelDeploymentLogExcerpt(
          deploymentID: deploymentID,
          profile: profile,
          token: token
        )
      } else {
        logExcerpt = []
      }
      return DeploymentStatusSignal(
        level: level,
        title: deployment.name?.nilIfEmpty ?? "Vercel Deployment",
        message: messageParts.isEmpty
          ? CoreL10n.text("已读取最近一次 Vercel 部署。")
          : messageParts.joined(separator: " · "),
        urlText: urlText,
        logExcerpt: logExcerpt
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "Vercel Deployment",
        message: CoreL10n.format("读取 Vercel 部署状态失败：%@", error.localizedDescription)
      )
    }
  }

  func vercelDeploymentLogExcerpt(
    deploymentID: String,
    profile: SiteProfile,
    token: String
  ) async -> [DeploymentLogEntry] {
    do {
      var queryItems = [
        URLQueryItem(name: "direction", value: "backward"),
        URLQueryItem(name: "follow", value: "0"),
        URLQueryItem(name: "limit", value: "100"),
      ]
      if let teamID = profile.deploymentAccountID?.trimmedForPublishing.nilIfEmpty {
        queryItems.append(URLQueryItem(name: "teamId", value: teamID))
      }
      let request = try vercelRequest(
        path: "/v3/deployments/\(encodedPathComponent(deploymentID))/events",
        token: token,
        queryItems: queryItems
      )
      let data = try await sendData(request)
      return VercelDeploymentLogParser.parse(data: data)
    } catch {
      return []
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
        return DeploymentStatusSignal(
          level: .unknown,
          title: "Cloudflare Pages",
          message: CoreL10n.text("没有找到最近的 Pages 部署记录。")
        )
      }

      let status = deployment.latestStage?.status?.nilIfEmpty
      let trigger = deployment.deploymentTrigger?.metadata
      let messageParts = [
        status.map { CoreL10n.format("状态：%@", $0) },
        trigger?.branch?.nilIfEmpty.map { CoreL10n.format("分支：%@", $0) },
        trigger?.commitHash?.nilIfEmpty.map { CoreL10n.format("提交：%@", $0) },
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
        message: messageParts.isEmpty
          ? CoreL10n.text("已读取最近一次 Cloudflare Pages 部署。")
          : messageParts.joined(separator: " · "),
        urlText: urlText
      )
    } catch {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "Cloudflare Pages",
        message: CoreL10n.format("读取 Cloudflare Pages 部署状态失败：%@", error.localizedDescription)
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
      mismatches.append(
        CoreL10n.format("期望提交 %@，实际 %@", shortCommit(expectedCommit), shortCommit(actualCommit))
      )
    }
    if let expectedBranch, let actualBranch,
       actualBranch.compare(expectedBranch, options: [.caseInsensitive]) != .orderedSame {
      mismatches.append(CoreL10n.format("期望分支 %@，实际 %@", expectedBranch, actualBranch))
    }

    guard !mismatches.isEmpty else {
      return nil
    }
    return CoreL10n.format(
      "最近一次 %@ 部署不是当前发布：%@。请等待目标 commit 部署完成或检查部署队列。",
      provider.displayName,
      mismatches.joined(separator: CoreL10n.text("；"))
    )
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
