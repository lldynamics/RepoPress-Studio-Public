import Foundation

extension DeploymentStatusService {

  public func check(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord? = nil,
    token: String? = nil
  ) async -> DeploymentStatusSnapshot {
    let provider = profile.deploymentProvider ?? defaultProvider(for: profile)
    let siteURLText =
      normalizedURLText(profile.deploymentSiteURL)
      ?? inferredSiteURL(profile: profile, provider: provider)
    let explicitEndpointURLText = normalizedURLText(profile.deploymentStatusEndpointURL)
    let endpointURLText = explicitEndpointURLText ?? siteURLText
    let canUseEndpointToken =
      provider == .custom
      && explicitEndpointURLText != nil
      && profile.deploymentStatusEndpointUsesToken == true
    var signals: [DeploymentStatusSignal] = []

    switch provider {
    case .githubPages:
      signals.append(
        contentsOf: await githubSignals(
          profile: profile, releaseRecord: releaseRecord, token: token))
    case .gitlabPages:
      signals.append(
        contentsOf: await gitLabSignals(
          profile: profile, releaseRecord: releaseRecord, token: token))
    case .netlify:
      signals.append(
        contentsOf: await netlifySignals(
          profile: profile, releaseRecord: releaseRecord, token: token))
    case .vercel:
      signals.append(
        contentsOf: await vercelSignals(
          profile: profile, releaseRecord: releaseRecord, token: token))
    case .cloudflarePages:
      signals.append(
        contentsOf: await cloudflarePagesSignals(
          profile: profile, releaseRecord: releaseRecord, token: token))
    case .custom:
      break
    }

    if let endpointURLText {
      signals.append(
        await endpointSignal(
          urlText: endpointURLText,
          provider: provider,
          profile: profile,
          releaseRecord: provider == .custom ? releaseRecord : nil,
          token: token,
          usesToken: canUseEndpointToken
        )
      )
    } else if signals.isEmpty {
      signals.append(
        DeploymentStatusSignal(
          level: .unknown,
          title: CoreL10n.text("缺少状态端点"),
          message: CoreL10n.text("请在 Profile 设置中填写站点 URL 或状态端点。")
        )
      )
    }
    if let siteURLText {
      signals.append(
        contentsOf: await articlePageSignals(
          siteURLText: siteURLText,
          profile: profile,
          releaseRecord: releaseRecord
        )
      )
    }

    let expectedCommitSHA = releaseRecord?.commitSHA?.trimmedForPublishing.nilIfEmpty
    if let expectedCommitSHA,
      !signals.contains(where: { $0.attributionVerified != nil })
    {
      signals.append(
        deploymentAttributionSignal(
          provider: provider,
          message: CoreL10n.format(
            "部署检查没有返回当前发布提交 %@，不能确认该版本已经上线。",
            shortCommit(expectedCommitSHA)
          ),
          urlText: nil,
          deploymentBranch: nil,
          deploymentCommit: nil,
          releaseRecord: releaseRecord,
          profile: profile,
          verified: false
        )
      )
    }

    let level = aggregateLevel(signals)
    let attributionSignal =
      signals.first(where: { $0.attributionVerified == true })
      ?? signals.first(where: { $0.attributionVerified == false })
    return DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: releaseRecord?.id,
      provider: provider,
      level: level,
      title: CoreL10n.format("%@ · %@", provider.displayName, level.displayName),
      message: aggregateMessage(level: level, signals: signals),
      siteURLText: siteURLText,
      signals: signals,
      expectedBranch: expectedDeploymentBranch(releaseRecord: releaseRecord, profile: profile),
      expectedCommitSHA: expectedCommitSHA,
      observedBranch: attributionSignal?.observedBranch,
      observedCommitSHA: attributionSignal?.observedCommitSHA,
      attributionVerified: expectedCommitSHA == nil
        ? nil
        : attributionSignal?.attributionVerified == true
    )
  }

  public func readiness(
    profile: SiteProfile,
    hasToken: Bool
  ) -> DeploymentStatusProviderReadiness {
    let provider = profile.deploymentProvider ?? defaultProvider(for: profile)
    let hasRepository = hasRepositoryConfiguration(profile)
    let hasProjectID = profile.deploymentProjectID?.trimmedForPublishing.nilIfEmpty != nil
    let hasAccountID = profile.deploymentAccountID?.trimmedForPublishing.nilIfEmpty != nil
    let hasSiteURL =
      normalizedURLText(profile.deploymentSiteURL) != nil
      || inferredSiteURL(profile: profile, provider: provider) != nil
    let statusEndpointURL = normalizedURLText(profile.deploymentStatusEndpointURL).flatMap(
      URL.init(string:))
    let hasStatusEndpoint = statusEndpointURL != nil
    let endpointTokenRequested = profile.deploymentStatusEndpointUsesToken == true
    let endpointUsesToken = endpointTokenRequested && provider == .custom
    let hasSecureProtectedEndpoint =
      !endpointUsesToken
      || statusEndpointURL.map(CredentialedEndpointPolicy.isSecureRequestURL) == true
    let hasUsableStatusEndpoint = hasStatusEndpoint && hasSecureProtectedEndpoint
    let hasReachabilityFallback = hasSiteURL || hasUsableStatusEndpoint
    let repositoryAPIBaseURLText =
      profile.repositoryBaseURL.nilIfEmpty
      ?? profile.repositoryProvider.defaultBaseURL
    let hasSecureRepositoryAPI =
      URL(string: repositoryAPIBaseURLText)
      .map(CredentialedEndpointPolicy.isSecureAPIBaseURL) == true
    var configured: [String] = []
    var missing: [String] = []
    var apiReady = false

    if hasToken {
      configured.append(CoreL10n.text("部署 Token"))
    } else {
      missing.append(CoreL10n.text("部署 Token"))
    }

    if hasSiteURL {
      configured.append(CoreL10n.text("站点 URL"))
    }
    if hasStatusEndpoint {
      configured.append(CoreL10n.text("状态端点 URL"))
      if endpointUsesToken {
        if !hasSecureProtectedEndpoint {
          missing.append(CoreL10n.text("状态端点 HTTPS URL"))
        } else if hasToken {
          configured.append(CoreL10n.text("状态端点 Bearer Token"))
        } else {
          missing.append(CoreL10n.text("状态端点 Bearer Token"))
        }
      }
    }

    switch provider {
    case .githubPages:
      if hasRepository {
        configured.append("GitHub owner/repository")
      } else {
        missing.append("GitHub owner/repository")
      }
      if !hasSecureRepositoryAPI {
        missing.append(CoreL10n.text("仓库 API HTTPS URL"))
      }
      apiReady = hasRepository && hasToken && hasSecureRepositoryAPI
    case .gitlabPages:
      if hasRepository {
        configured.append("GitLab namespace/project")
      } else {
        missing.append("GitLab namespace/project")
      }
      if !hasSecureRepositoryAPI {
        missing.append(CoreL10n.text("仓库 API HTTPS URL"))
      }
      apiReady = hasRepository && hasToken && hasSecureRepositoryAPI
    case .netlify:
      if hasProjectID {
        configured.append("Netlify Site ID")
      } else {
        missing.append("Netlify Site ID")
      }
      apiReady = hasProjectID && hasToken
    case .vercel:
      if hasProjectID {
        configured.append("Vercel Project ID")
      } else {
        missing.append("Vercel Project ID")
      }
      if hasAccountID {
        configured.append("Vercel Team ID")
      }
      apiReady = hasProjectID && hasToken
    case .cloudflarePages:
      if hasAccountID {
        configured.append("Cloudflare Account ID")
      } else {
        missing.append("Cloudflare Account ID")
      }
      if hasProjectID {
        configured.append("Cloudflare Pages project")
      } else {
        missing.append("Cloudflare Pages project")
      }
      apiReady = hasAccountID && hasProjectID && hasToken
    case .custom:
      if !hasReachabilityFallback {
        missing.append(CoreL10n.text("站点 URL 或状态端点 URL"))
      }
      apiReady =
        hasReachabilityFallback
        && (!endpointUsesToken || (hasSecureProtectedEndpoint && hasToken))
    }

    let hasProviderConfiguration: Bool
    switch provider {
    case .githubPages, .gitlabPages:
      hasProviderConfiguration = hasRepository
    case .netlify, .vercel:
      hasProviderConfiguration = hasProjectID
    case .cloudflarePages:
      hasProviderConfiguration = hasAccountID && hasProjectID
    case .custom:
      hasProviderConfiguration = hasReachabilityFallback
    }

    var fallbackMessage: String
    if hasStatusEndpoint && endpointTokenRequested && provider != .custom {
      fallbackMessage = CoreL10n.text(
        "只有自定义平台可向状态端点发送部署 Token；当前平台的端点将按无授权方式检查，避免将平台 Token 发送到第三方域名。")
    } else if hasStatusEndpoint && endpointUsesToken && !hasSecureProtectedEndpoint {
      fallbackMessage = CoreL10n.text("受保护状态端点必须使用 HTTPS；当前端点已禁用，不会发送 Bearer Token。")
    } else if hasReachabilityFallback {
      fallbackMessage = CoreL10n.text("已配置站点 URL 或状态端点；即使 API 未就绪，也能检查 HTTP 可达性和文章页面内容。")
      if hasStatusEndpoint && endpointUsesToken {
        fallbackMessage += CoreL10n.text(" 状态端点会在保存 Token 后使用 Bearer 授权。")
      }
    } else {
      fallbackMessage = CoreL10n.text("未配置可用的站点 URL 或状态端点；API 未就绪时无法做发布后降级校验。")
    }
    let nextStep: String
    if apiReady {
      nextStep = CoreL10n.format("可以读取 %@ 的部署状态，并继续保留站点 URL 做发布后页面校验。", provider.displayName)
    } else if hasProviderConfiguration {
      nextStep = CoreL10n.format(
        "补齐 %@ 后可读取 %@ API 状态。",
        missing.joined(separator: CoreL10n.text("、")),
        provider.displayName
      )
    } else {
      nextStep = CoreL10n.format(
        "先补齐 %@。",
        missing.joined(separator: CoreL10n.text("、"))
      )
    }

    return DeploymentStatusProviderReadiness(
      provider: provider,
      isAPIReady: apiReady,
      canCheckAnyStatus: hasProviderConfiguration || hasReachabilityFallback,
      configuredSignals: configured,
      missingRequirements: Array(Set(missing)).sorted(),
      fallbackMessage: fallbackMessage,
      nextStep: nextStep
    )
  }
  private func defaultProvider(for profile: SiteProfile) -> DeploymentProvider {
    switch profile.repositoryProvider {
    case .github:
      return .githubPages
    case .gitlab:
      return .gitlabPages
    }
  }

  public func hasRepositoryConfiguration(_ profile: SiteProfile) -> Bool {
    !profile.repoOwner.trimmedForPublishing.isEmpty
      && !profile.repoName.trimmedForPublishing.isEmpty
  }

  private func inferredSiteURL(profile: SiteProfile, provider: DeploymentProvider) -> String? {
    let owner = profile.repoOwner.trimmedForPublishing
    let repo = profile.repoName.trimmedForPublishing
    guard !owner.isEmpty, !repo.isEmpty else {
      return nil
    }

    switch provider {
    case .githubPages:
      if repo.lowercased() == "\(owner.lowercased()).github.io" {
        return "https://\(owner).github.io/"
      }
      return "https://\(owner).github.io/\(repo)/"
    case .gitlabPages:
      let namespace = owner.split(separator: "/").first.map(String.init) ?? owner
      return "https://\(namespace).gitlab.io/\(repo)/"
    case .netlify, .vercel, .cloudflarePages, .custom:
      return nil
    }
  }

  public func normalizedURLText(_ value: String?) -> String? {
    let trimmed = value?.trimmedForPublishing ?? ""
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      return trimmed
    }
    return "https://\(trimmed)"
  }

  public func articleURL(siteURLText: String, markdownPath: String, siteKind: SiteKind) -> String? {
    guard let siteURL = URL(string: siteURLText) else { return nil }
    return SiteArticleURLResolver()
      .url(baseURL: siteURL, markdownPath: markdownPath, siteKind: siteKind)?
      .absoluteString
  }

  private func aggregateLevel(_ signals: [DeploymentStatusSignal]) -> DeploymentStatusLevel {
    if signals.contains(where: { $0.level == .failed }) {
      return .failed
    }
    if signals.contains(where: { $0.level == .running }) {
      return .running
    }
    if !signals.isEmpty, signals.allSatisfy({ $0.level == .success }) {
      return .success
    }
    return .unknown
  }

  private func aggregateMessage(level: DeploymentStatusLevel, signals: [DeploymentStatusSignal])
    -> String
  {
    switch level {
    case .success:
      return CoreL10n.text("部署 API 和站点端点检查通过。")
    case .running:
      return CoreL10n.text("部署仍在运行，稍后可再次刷新。")
    case .failed:
      return signals.first(where: { $0.level == .failed })?.message
        ?? CoreL10n.text("部署检查失败。")
    case .unknown:
      return signals.first(where: { $0.level == .unknown })?.message
        ?? CoreL10n.text("部署状态还不能确认。")
    }
  }

}
