import Foundation

public struct ReleaseQualityGateReport: Codable, Hashable, Sendable {
  public var generatedAt: Date
  public var projectRootPath: String
  public var items: [ReleaseQualityGateItem]
  public var screenshotRequirements: [ReleaseScreenshotRequirement]
  public var externalVerificationItems: [ReleaseExternalVerificationItem]
  public var appStoreChecklistTasks: [ReleaseAppStoreChecklistTask]
  public var externalVerificationEvidenceFileStatus: ReleaseExternalVerificationEvidenceFileStatus

  public init(
    generatedAt: Date = Date(),
    projectRootPath: String,
    items: [ReleaseQualityGateItem],
    screenshotRequirements: [ReleaseScreenshotRequirement] = [],
    externalVerificationItems: [ReleaseExternalVerificationItem] = [],
    appStoreChecklistTasks: [ReleaseAppStoreChecklistTask] = [],
    externalVerificationEvidenceFileStatus: ReleaseExternalVerificationEvidenceFileStatus = ReleaseExternalVerificationEvidenceFileStatus()
  ) {
    self.generatedAt = generatedAt
    self.projectRootPath = projectRootPath
    self.items = items
    self.screenshotRequirements = screenshotRequirements
    self.externalVerificationItems = externalVerificationItems
    self.appStoreChecklistTasks = appStoreChecklistTasks
    self.externalVerificationEvidenceFileStatus = externalVerificationEvidenceFileStatus
  }

  private enum CodingKeys: String, CodingKey {
    case generatedAt
    case projectRootPath
    case items
    case screenshotRequirements
    case externalVerificationItems
    case appStoreChecklistTasks
    case externalVerificationEvidenceFileStatus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    projectRootPath = try container.decode(String.self, forKey: .projectRootPath)
    items = try container.decode([ReleaseQualityGateItem].self, forKey: .items)
    screenshotRequirements = try container.decodeIfPresent(
      [ReleaseScreenshotRequirement].self,
      forKey: .screenshotRequirements
    ) ?? []
    externalVerificationItems = try container.decodeIfPresent(
      [ReleaseExternalVerificationItem].self,
      forKey: .externalVerificationItems
    ) ?? []
    appStoreChecklistTasks = try container.decodeIfPresent(
      [ReleaseAppStoreChecklistTask].self,
      forKey: .appStoreChecklistTasks
    ) ?? []
    externalVerificationEvidenceFileStatus = try container.decodeIfPresent(
      ReleaseExternalVerificationEvidenceFileStatus.self,
      forKey: .externalVerificationEvidenceFileStatus
    ) ?? ReleaseExternalVerificationEvidenceFileStatus()
  }

  public static var empty: ReleaseQualityGateReport {
    ReleaseQualityGateReport(projectRootPath: "", items: [])
  }

  public var blockingItems: [ReleaseQualityGateItem] {
    items.filter { $0.status == .blocked }
  }

  public var warningItems: [ReleaseQualityGateItem] {
    items.filter { $0.status == .warning }
  }

  public var passedItems: [ReleaseQualityGateItem] {
    items.filter { $0.status == .passed }
  }

  public var capturedScreenshotRequirements: [ReleaseScreenshotRequirement] {
    screenshotRequirements.filter(\.isCaptured)
  }

  public var missingScreenshotRequirements: [ReleaseScreenshotRequirement] {
    screenshotRequirements.filter { !$0.isCaptured }
  }

  public var isReadyForAppStore: Bool {
    blockingItems.isEmpty && warningItems.isEmpty
  }

  func releaseGateItemStatus(id: String) -> ReleaseQualityGateStatus? {
    items.first { $0.id == id }?.status
  }

  public var sections: [ReleaseQualityGateSection] {
    ReleaseQualityGateCategory.allCases.compactMap { category in
      let categoryItems = items.filter { $0.category == category }
      guard !categoryItems.isEmpty else { return nil }
      return ReleaseQualityGateSection(category: category, items: categoryItems)
    }
  }

  public var screenshotCapturePlanMarkdown: String {
    var lines = [
      "# App Store 截图采集计划",
      "",
      "- 项目：\(projectRootPath)",
      "- 已采集：\(capturedScreenshotRequirements.count)/\(screenshotRequirements.count)",
      "- 缺失：\(missingScreenshotRequirements.map(\.id).joined(separator: "、").nilIfEmpty ?? "无")",
      "",
      "## 全量命令",
      "",
      "```sh",
      "./script/capture_app_screenshots.sh",
      "./script/check_release_gate.sh --strict",
      "```",
      "",
      "## 单项采集",
    ]

    if screenshotRequirements.isEmpty {
      lines.append("- 当前报告没有截图需求。")
    } else {
      lines.append(contentsOf: screenshotRequirements.map(\.capturePlanMarkdown))
    }

    return lines.joined(separator: "\n")
  }

  public var appStoreScreenshotEvidenceRecordingCommandMarkdown: String {
    [
      "# App Store Screenshot Evidence Recording Commands",
      "",
      "Use these commands only after the App Store screenshots have been captured from redacted demo data and reviewed for privacy.",
      "Private env template: `docs/release-evidence/app-store-screenshots.env.example`; fill the copied `app-store-screenshots.env` outside the repository.",
      "",
      "```sh",
      "script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target app-store-screenshots",
      "source /private/tmp/personal-site-publisher-release-envs/app-store-screenshots.env",
      "script/check_app_store_screenshot_capture_readiness.sh",
      "script/capture_app_screenshots.sh --auto-window --force-relaunch",
      "script/check_screenshots.sh",
      "script/check_screenshot_privacy.sh",
      "script/record_app_store_screenshot_evidence.sh --execute",
      "script/check_release_gate.sh --strict",
      "```",
    ].joined(separator: "\n")
  }

}

public struct ReleaseProductCapabilityCoverage: Codable, Hashable, Sendable {
  public var onlinePublishing: Bool
  public var remoteSyncCenter: Bool
  public var repositoryAutoSync: Bool
  public var seoSocialPreview: Bool
  public var deploymentStatusPanel: Bool
  public var siteMaintenanceWorkspace: Bool
  public var releaseLedgerRollback: Bool
  public var generalDraftWorkspace: Bool
  public var privacyProtection: Bool
  public var proBoundary: Bool
  public var aiChatWorkspace: Bool

  public init(
    onlinePublishing: Bool = true,
    remoteSyncCenter: Bool = true,
    repositoryAutoSync: Bool = true,
    seoSocialPreview: Bool = true,
    deploymentStatusPanel: Bool = true,
    siteMaintenanceWorkspace: Bool = true,
    releaseLedgerRollback: Bool = true,
    generalDraftWorkspace: Bool = true,
    privacyProtection: Bool = true,
    proBoundary: Bool = true,
    aiChatWorkspace: Bool = true
  ) {
    self.onlinePublishing = onlinePublishing
    self.remoteSyncCenter = remoteSyncCenter
    self.repositoryAutoSync = repositoryAutoSync
    self.seoSocialPreview = seoSocialPreview
    self.deploymentStatusPanel = deploymentStatusPanel
    self.siteMaintenanceWorkspace = siteMaintenanceWorkspace
    self.releaseLedgerRollback = releaseLedgerRollback
    self.generalDraftWorkspace = generalDraftWorkspace
    self.privacyProtection = privacyProtection
    self.proBoundary = proBoundary
    self.aiChatWorkspace = aiChatWorkspace
  }
}
