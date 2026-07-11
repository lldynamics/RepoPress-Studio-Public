import Foundation

public extension DeploymentStatusService {

  func check(
    profile: SiteProfile,
    releaseRecord: ReleaseRecord? = nil,
    token: String? = nil
  ) async -> DeploymentStatusSnapshot {
    let provider = profile.deploymentProvider ?? defaultProvider(for: profile)
    let siteURLText = normalizedURLText(profile.deploymentSiteURL)
      ?? inferredSiteURL(profile: profile, provider: provider)
    let explicitEndpointURLText = normalizedURLText(profile.deploymentStatusEndpointURL)
    let endpointURLText = explicitEndpointURLText ?? siteURLText
    let canUseEndpointToken = explicitEndpointURLText != nil
      && profile.deploymentStatusEndpointUsesToken == true
    var signals: [DeploymentStatusSignal] = []

    switch provider {
    case .githubPages:
      signals.append(contentsOf: await githubSignals(profile: profile, releaseRecord: releaseRecord, token: token))
    case .gitlabPages:
      signals.append(contentsOf: await gitLabSignals(profile: profile, releaseRecord: releaseRecord, token: token))
    case .netlify:
      signals.append(contentsOf: await netlifySignals(profile: profile, releaseRecord: releaseRecord, token: token))
    case .vercel:
      signals.append(contentsOf: await vercelSignals(profile: profile, releaseRecord: releaseRecord, token: token))
    case .cloudflarePages:
      signals.append(contentsOf: await cloudflarePagesSignals(profile: profile, releaseRecord: releaseRecord, token: token))
    case .custom:
      break
    }

    if let endpointURLText {
      signals.append(
        await endpointSignal(
          urlText: endpointURLText,
          provider: provider,
          token: token,
          usesToken: canUseEndpointToken
        )
      )
    } else if signals.isEmpty {
      signals.append(
        DeploymentStatusSignal(
          level: .unknown,
          title: "缺少状态端点",
          message: "请在 Profile 设置中填写站点 URL 或状态端点。"
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

    let level = aggregateLevel(signals)
    return DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: releaseRecord?.id,
      provider: provider,
      level: level,
      title: "\(provider.displayName) · \(level.displayName)",
      message: aggregateMessage(level: level, signals: signals),
      siteURLText: siteURLText,
      signals: signals
    )
  }

  func readiness(
    profile: SiteProfile,
    hasToken: Bool
  ) -> DeploymentStatusProviderReadiness {
    let provider = profile.deploymentProvider ?? defaultProvider(for: profile)
    let hasRepository = hasRepositoryConfiguration(profile)
    let hasProjectID = profile.deploymentProjectID?.trimmedForPublishing.nilIfEmpty != nil
    let hasAccountID = profile.deploymentAccountID?.trimmedForPublishing.nilIfEmpty != nil
    let hasSiteURL = normalizedURLText(profile.deploymentSiteURL) != nil
      || inferredSiteURL(profile: profile, provider: provider) != nil
    let hasStatusEndpoint = normalizedURLText(profile.deploymentStatusEndpointURL) != nil
    let endpointUsesToken = profile.deploymentStatusEndpointUsesToken == true
    let hasReachabilityFallback = hasSiteURL || hasStatusEndpoint
    var configured: [String] = []
    var missing: [String] = []
    var apiReady = false

    if hasToken {
      configured.append("部署 Token")
    } else {
      missing.append("部署 Token")
    }

    if hasSiteURL {
      configured.append("站点 URL")
    }
    if hasStatusEndpoint {
      configured.append("状态端点 URL")
      if endpointUsesToken {
        if hasToken {
          configured.append("状态端点 Bearer Token")
        } else {
          missing.append("状态端点 Bearer Token")
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
      apiReady = hasRepository && hasToken
    case .gitlabPages:
      if hasRepository {
        configured.append("GitLab namespace/project")
      } else {
        missing.append("GitLab namespace/project")
      }
      apiReady = hasRepository && hasToken
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
        missing.append("站点 URL 或状态端点 URL")
      }
      apiReady = hasReachabilityFallback
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

    let fallbackMessage = hasReachabilityFallback
      ? "已配置站点 URL 或状态端点；即使 API 未就绪，也能检查 HTTP 可达性和文章页面内容。\(hasStatusEndpoint && endpointUsesToken ? " 状态端点会在保存 Token 后使用 Bearer 授权。" : "")"
      : "未配置站点 URL 或状态端点；API 未就绪时无法做发布后降级校验。"
    let nextStep: String
    if apiReady {
      nextStep = "可以读取 \(provider.displayName) 的部署状态，并继续保留站点 URL 做发布后页面校验。"
    } else if hasProviderConfiguration {
      nextStep = "补齐 \(missing.joined(separator: "、")) 后可读取 \(provider.displayName) API 状态。"
    } else {
      nextStep = "先补齐 \(missing.joined(separator: "、"))。"
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

  func hasRepositoryConfiguration(_ profile: SiteProfile) -> Bool {
    !profile.repoOwner.trimmedForPublishing.isEmpty && !profile.repoName.trimmedForPublishing.isEmpty
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

  func normalizedURLText(_ value: String?) -> String? {
    let trimmed = value?.trimmedForPublishing ?? ""
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      return trimmed
    }
    return "https://\(trimmed)"
  }

  func articleURL(siteURLText: String, markdownPath: String, siteKind: SiteKind) -> String? {
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

  private func aggregateMessage(level: DeploymentStatusLevel, signals: [DeploymentStatusSignal]) -> String {
    switch level {
    case .success:
      return "部署 API 和站点端点检查通过。"
    case .running:
      return "部署仍在运行，稍后可再次刷新。"
    case .failed:
      return signals.first(where: { $0.level == .failed })?.message ?? "部署检查失败。"
    case .unknown:
      return signals.first(where: { $0.level == .unknown })?.message ?? "部署状态还不能确认。"
    }
  }

}
