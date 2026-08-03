import Foundation

extension WorkbenchStore {
  public func makeDiagnosticsContext(
    appVersion: String,
    buildVersion: String
  ) -> WorkbenchDiagnosticsContext {
    let siteDraftFileFailureMessages = siteDraftFileSaveStates.values.compactMap { state -> String? in
      guard case .failed(_, let message) = state else { return nil }
      return message
    }
    let messages = [
      lastSaveError,
      persistenceRecoveryMessage,
      publishActionMessage,
      deploymentStatusMessage,
      repositoryAutoSyncState.fetchMessage,
      aiActionMessage,
      imageActionMessage,
      siteDraftFileFailureMessages.joined(separator: "\n").nilIfEmpty,
    ].compactMap { $0?.trimmedForPublishing.nilIfEmpty }

    return WorkbenchDiagnosticsContext(
      appVersion: appVersion,
      buildVersion: buildVersion,
      isSafeMode: isSafeMode,
      isQuickHideActive: isQuickHideActive,
      hasPersistenceRecoveryMessage: persistenceRecoveryMessage != nil,
      draftCount: drafts.count,
      pendingDraftRecoveryCount: pendingDraftRecoveries.count,
      profileCount: profiles.count,
      activeSiteKind: activeProfile.siteKind.displayName,
      repositoryProvider: activeProfile.repositoryProvider.displayName,
      hasLocalRepository: activeProfile.localRepositoryRootURL != nil,
      hasRepositoryToken: repositoryTokenAvailability.hasToken,
      hasDeploymentToken: deploymentTokenAvailability.hasToken,
      lastSaveStatus: lastSaveStatus,
      statusMessages: messages
    )
  }

  @discardableResult
  public func exportRedactedDiagnostics(
    to directoryURL: URL,
    appVersion: String,
    buildVersion: String
  ) throws -> URL {
    let context = makeDiagnosticsContext(
      appVersion: appVersion,
      buildVersion: buildVersion
    )
    let archiveURL = try WorkbenchDiagnosticsExportService().export(
      context: context,
      to: directoryURL
    )
    setLastSaveStatus(CoreL10n.text("已导出脱敏诊断包"))
    return archiveURL
  }
}
