import Foundation
import PublishingDomainContracts

extension DeploymentStore {
  public func deploymentStatusReadiness(
    for profile: SiteProfile,
    tokenAvailability: KeychainTokenAvailability
  ) -> DeploymentStatusProviderReadiness {
    var readiness = deploymentStatusReadiness(
      for: profile,
      hasToken: tokenAvailability.hasToken
    )
    let hasCustomStatusEndpoint = readiness.configuredSignals.contains(
      CoreL10n.text("状态端点 URL"))
    let tokenIsRequired =
      readiness.provider != .custom
      || (profile.deploymentStatusEndpointUsesToken == true && hasCustomStatusEndpoint)
    if !tokenIsRequired {
      readiness.missingRequirements.removeAll {
        $0 == CoreL10n.text("部署 Token")
      }
      if !readiness.canCheckAnyStatus {
        readiness.nextStep = CoreL10n.format(
          "先补齐 %@。",
          readiness.missingRequirements.joined(separator: CoreL10n.text("、"))
        )
      }
      return readiness
    }
    guard let accessFailureMessage = tokenAvailability.accessFailureMessage else {
      return readiness
    }
    let accessFailureRequirement = CoreL10n.format(
      "部署 Token 状态读取失败：%@",
      accessFailureMessage
    )
    readiness.fallbackMessage = [
      readiness.fallbackMessage,
      accessFailureRequirement,
    ].joined(separator: " ")
    return readiness
  }
}
