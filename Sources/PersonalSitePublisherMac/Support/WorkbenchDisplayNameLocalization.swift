import Foundation
import PublishingWorkbenchCore
import SwiftUI

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
extension AIPublishingQuickPromptGroup: WorkbenchDisplayNameLocalizable {}
extension AIPublishingQuickPrompt: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatRole: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatContextMode: WorkbenchDisplayNameLocalizable {}
extension AIPublishingChatDraftApplicationMode: WorkbenchDisplayNameLocalizable {}
extension AIPublishingSelectionEditApplication: WorkbenchDisplayNameLocalizable {}
extension SiteMaintenanceHealthLevel: WorkbenchDisplayNameLocalizable {}
extension MaintenanceActionPriority: WorkbenchDisplayNameLocalizable {}
extension MaintenanceActionKind: WorkbenchDisplayNameLocalizable {}

extension AIPublishingActionKind: WorkbenchDisplayNameLocalizable {}
extension BatchPublishReadiness: WorkbenchDisplayNameLocalizable {}
extension ContentMigrationSourceKind: WorkbenchDisplayNameLocalizable {}
extension DeploymentPollingStatus: WorkbenchDisplayNameLocalizable {}
extension GeneralDraftReuseRiskLevel: WorkbenchDisplayNameLocalizable {}
extension GeneralDraftReuseStatus: WorkbenchDisplayNameLocalizable {}
extension ImageCoverPublishState: WorkbenchDisplayNameLocalizable {}
extension LocalGitPublishMode: WorkbenchDisplayNameLocalizable {}
extension PremiumFeature: WorkbenchDisplayNameLocalizable {}
extension PrivacyProtectionEventKind: WorkbenchDisplayNameLocalizable {}
extension ProEntitlementSource: WorkbenchDisplayNameLocalizable {}
extension RemoteRepositoryPublishProgressStage: WorkbenchDisplayNameLocalizable {}
extension RemoteRepositoryPublishReadiness: WorkbenchDisplayNameLocalizable {}
extension RepositoryAutoSyncStatus: WorkbenchDisplayNameLocalizable {}
extension SEOSocialPreviewCacheState: WorkbenchDisplayNameLocalizable {}
extension SEOSocialPreviewCardKind: WorkbenchDisplayNameLocalizable {}
extension AIChatTranscriptExportFormat: WorkbenchDisplayNameLocalizable {}
extension DraftListFilter: WorkbenchDisplayNameLocalizable {}
extension MonetizationAccessEventOutcome: WorkbenchDisplayNameLocalizable {}
extension RepositoryChangedFileRole: WorkbenchDisplayNameLocalizable {}
extension RepositoryChangeKind: WorkbenchDisplayNameLocalizable {}
extension SEOSocialPreviewReadinessStatus: WorkbenchDisplayNameLocalizable {}
extension WritingDraftDensity: WorkbenchDisplayNameLocalizable {}
