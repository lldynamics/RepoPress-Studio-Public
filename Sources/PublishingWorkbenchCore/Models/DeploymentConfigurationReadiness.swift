import Foundation

/// Describes whether a publishing profile has the explicit values needed to
/// treat deployment checks as production evidence. Repository-derived defaults
/// remain available for compatibility checks, but are never production setup.
public struct DeploymentConfigurationReadiness: Hashable, Sendable {
  public var requiresProductionVerification: Bool
  public var hasExplicitProvider: Bool
  public var hasExplicitSiteURL: Bool
  public var issues: [String]

  public init(profile: SiteProfile) {
    requiresProductionVerification = profile.purpose.requiresDeploymentReadiness
    hasExplicitProvider = profile.deploymentProvider != nil
    hasExplicitSiteURL = profile.deploymentSiteURL?.trimmedForPublishing.nilIfEmpty != nil

    guard requiresProductionVerification else {
      issues = []
      return
    }

    var issues: [String] = []
    if !hasExplicitProvider {
      issues.append(
        CoreL10n.text("未明确选择部署平台；当前仅显示基于仓库提供方的检查默认值。")
      )
    }
    if !hasExplicitSiteURL {
      issues.append(CoreL10n.text("未填写生产站点 URL；无法将检查结果作为生产页面验证。"))
    }

    if profile.deploymentProvider == .cloudflarePages {
      if profile.deploymentAccountID?.trimmedForPublishing.nilIfEmpty == nil {
        issues.append(CoreL10n.text("未填写 Cloudflare Account ID。"))
      }
      if profile.deploymentProjectID?.trimmedForPublishing.nilIfEmpty == nil {
        issues.append(CoreL10n.text("未填写 Cloudflare Pages 项目。"))
      }
    }

    self.issues = issues
  }

  public var needsExplicitProviderConfirmation: Bool {
    requiresProductionVerification && !hasExplicitProvider
  }
}
