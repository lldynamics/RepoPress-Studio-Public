import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Centralized user-facing terminology for technical publishing concepts.
/// Use the explanatory form at the first prominent entry point, then the
/// concise form inside repeated controls and workflow steps.
enum WorkbenchUITerminology {
  static let siteConfiguration = String(localized: "站点配置")
  static let siteConfigurationIntroduction = String(localized: "站点配置（Profile）")
  static let difference = String(localized: "差异")
  static let differenceIntroduction = String(localized: "差异（Diff）")
  static let accessToken = String(localized: "访问令牌")
  static let accessTokenIntroduction = String(localized: "访问令牌（Token）")
  static let repositoryAccessTokenIntroduction = String(localized: "仓库访问令牌（Token）")
  static let deploymentAccessTokenIntroduction = String(localized: "部署访问令牌（Token）")
  static let articleHeader = String(localized: "文章头信息")
  static let articleHeaderIntroduction = String(localized: "文章头信息（Front Matter）")
}

protocol WorkbenchDisplayNameLocalizable {
  var workbenchDisplayNameSemanticKey: String { get }
  var fallbackDisplayName: String { get }
}

extension WorkbenchDisplayNameLocalizable {
  var localizedDisplayName: String {
    workbenchLocalizedDisplayNameString(self)
  }

  var localizedDisplayNameKey: LocalizedStringKey {
    workbenchLocalizedDisplayNameKey(self)
  }
}

func workbenchLocalizedDisplayNameKey<Value: WorkbenchDisplayNameLocalizable>(
  _ value: Value
) -> LocalizedStringKey {
  LocalizedStringKey(value.workbenchDisplayNameSemanticKey)
}

func workbenchLocalizedDisplayNameString<Value: WorkbenchDisplayNameLocalizable>(
  _ value: Value
) -> String {
  NSLocalizedString(
    value.workbenchDisplayNameSemanticKey,
    tableName: nil,
    bundle: .main,
    value: value.fallbackDisplayName,
    comment: "Workbench display name"
  )
}

extension ImageDimensions {
  var workbenchDimensionText: String { displayName }
}

extension AssetResourceKind {
  /// Asset resource names are already localized by CoreL10n.
  var workbenchLocalizedDisplayName: String { displayName }
}

extension AssetResourceReferenceIssueKind {
  /// Asset reference issue names are already localized by CoreL10n.
  var workbenchLocalizedDisplayName: String { displayName }
}

extension SiteKind: WorkbenchDisplayNameLocalizable {}
extension FrontMatterStyle: WorkbenchDisplayNameLocalizable {}
extension SiteSlugValidationRule: WorkbenchDisplayNameLocalizable {}
extension RepositoryProvider: WorkbenchDisplayNameLocalizable {}
extension RepositoryPublishStrategy: WorkbenchDisplayNameLocalizable {}
extension SiteProfilePurpose: WorkbenchDisplayNameLocalizable {}
extension AIProviderPreset: WorkbenchDisplayNameLocalizable {}
extension AIWritingStylePreset: WorkbenchDisplayNameLocalizable {}
extension DeploymentProvider: WorkbenchDisplayNameLocalizable {}
extension SiteStarterDeploymentTarget: WorkbenchDisplayNameLocalizable {}

extension SiteAnalyticsProvider: WorkbenchDisplayNameLocalizable {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .plausible:
      return "display.site-analytics-provider.plausible"
    case .umami:
      return "display.site-analytics-provider.umami"
    case .cloudflare:
      return "display.site-analytics-provider.cloudflare"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension EditorDisplayMode: WorkbenchDisplayNameLocalizable {}
extension DraftStatus: WorkbenchDisplayNameLocalizable {}
extension ArticleVisibility: WorkbenchDisplayNameLocalizable {}
extension PreflightSeverity: WorkbenchDisplayNameLocalizable {}
extension LocalPublishActionReadiness: WorkbenchDisplayNameLocalizable {}
extension PublishFileDiffStatus: WorkbenchDisplayNameLocalizable {}
extension PublishFileKind: WorkbenchDisplayNameLocalizable {}
extension PublishFileOperation: WorkbenchDisplayNameLocalizable {}
extension DraftVersionReason: WorkbenchDisplayNameLocalizable {}
extension DraftRepositoryCleanupStatus: WorkbenchDisplayNameLocalizable {}
extension RemoteRepositoryPublishMode: WorkbenchDisplayNameLocalizable {}
extension DeploymentStatusLevel: WorkbenchDisplayNameLocalizable {}
extension ReleaseRecordKind: WorkbenchDisplayNameLocalizable {}
extension ReleaseLedgerStatus: WorkbenchDisplayNameLocalizable {}
extension ReleaseLedgerActionPriority: WorkbenchDisplayNameLocalizable {}
extension ReleaseLedgerActionKind: WorkbenchDisplayNameLocalizable {}

extension AIPublishingPromptLibraryScope: WorkbenchDisplayNameLocalizable {}
extension AIPublishingCapabilityCenterMode: WorkbenchDisplayNameLocalizable {}
extension AIPublishingDefaultCapability: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatQuickAction: WorkbenchDisplayNameLocalizable {}
extension AIPublishingQuickPromptGroup: WorkbenchDisplayNameLocalizable {}
extension AIPublishingQuickPrompt: WorkbenchDisplayNameLocalizable {}
extension AIContextReferenceKind: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatRole: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatContextMode: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatDraftApplicationMode: WorkbenchDisplayNameLocalizable {}
extension AIPublishingSelectionEditApplication: WorkbenchDisplayNameLocalizable {}
extension SiteMaintenanceHealthLevel: WorkbenchDisplayNameLocalizable {}
extension MaintenanceActionPriority: WorkbenchDisplayNameLocalizable {}
extension MaintenanceActionKind: WorkbenchDisplayNameLocalizable {}
extension WorkbenchAutomationRisk: WorkbenchDisplayNameLocalizable {}

extension AIPublishingActionKind: WorkbenchDisplayNameLocalizable {}
extension BatchPublishReadiness: WorkbenchDisplayNameLocalizable {}
extension ContentMigrationSourceKind: WorkbenchDisplayNameLocalizable {}
extension DeploymentPollingStatus: WorkbenchDisplayNameLocalizable {}
extension GeneralDraftReuseRiskLevel: WorkbenchDisplayNameLocalizable {}
extension ImageCoverPublishState: WorkbenchDisplayNameLocalizable {}
extension LocalGitPublishMode: WorkbenchDisplayNameLocalizable {}
extension PrivacyProtectionEventKind: WorkbenchDisplayNameLocalizable {}
extension RemoteRepositoryPublishProgressStage: WorkbenchDisplayNameLocalizable {}
extension RemoteRepositoryPublishReadiness: WorkbenchDisplayNameLocalizable {}
extension RepositoryAutoSyncStatus: WorkbenchDisplayNameLocalizable {}
extension SEOSocialPreviewCacheState: WorkbenchDisplayNameLocalizable {}
extension SEOSocialPreviewCardKind: WorkbenchDisplayNameLocalizable {}
extension DraftListFilter: WorkbenchDisplayNameLocalizable {}
extension RepositoryChangedFileRole: WorkbenchDisplayNameLocalizable {}
extension RepositoryChangeKind: WorkbenchDisplayNameLocalizable {}
extension SEOSocialPreviewReadinessStatus: WorkbenchDisplayNameLocalizable {}
extension WritingDraftSortOrder: WorkbenchDisplayNameLocalizable {}
extension KnowledgeDocumentKind: WorkbenchDisplayNameLocalizable {}
extension KnowledgeImportDisposition: WorkbenchDisplayNameLocalizable {}
extension KnowledgeDocumentSortField: WorkbenchDisplayNameLocalizable {}
extension KnowledgeSortDirection: WorkbenchDisplayNameLocalizable {}
extension WorkspaceBackupComponent: WorkbenchDisplayNameLocalizable {}
extension WorkspaceBackupFrequency: WorkbenchDisplayNameLocalizable {}
