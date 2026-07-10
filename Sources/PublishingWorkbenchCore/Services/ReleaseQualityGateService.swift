import Foundation
public struct ReleaseQualityGateService {
  private let coordinator: ReleaseQualityGateCoordinator

  public init(fileManager: FileManager = .default) {
    self.coordinator = ReleaseQualityGateCoordinator(fileManager: fileManager)
  }

  public func report(
    projectRoot: URL,
    workspaceSections: [WorkspaceSection] = WorkspaceNavigationPresentation.productReadinessSections,
    hasPrivacyProtection: Bool,
    hasProBoundary: Bool,
    proUpgradeRequirements: [ProUpgradeRequirement]? = nil,
    hasDeploymentStatusPanel: Bool,
    hasAIChatWorkspace: Bool,
    productCapabilities: ReleaseProductCapabilityCoverage? = nil
  ) -> ReleaseQualityGateReport {
    return coordinator.report(
      projectRoot: projectRoot,
      workspaceSections: workspaceSections,
      hasPrivacyProtection: hasPrivacyProtection,
      hasProBoundary: hasProBoundary,
      proUpgradeRequirements: proUpgradeRequirements,
      hasDeploymentStatusPanel: hasDeploymentStatusPanel,
      hasAIChatWorkspace: hasAIChatWorkspace,
      productCapabilities: productCapabilities
    )
  }
}
