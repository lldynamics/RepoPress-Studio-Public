import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsAITabFactory {
  static func make(context: SettingsContext) -> some View {
    AIConnectionManagerView(context: context)
  }

  static func makeEditor(
    context: SettingsContext, connectionID: UUID, selection: Binding<UUID>
  ) -> some View {
    let connection =
      context.store.aiConnectionProfile(for: connectionID)
      ?? context.store.activeAIConnectionProfile
    return AISettingsView(
      activeProfileBinding: context.activeProfileBinding,
      connectionProfiles: context.store.aiConnectionProfiles,
      referencingSiteProfiles: context.store.profiles,
      activeConnectionProfileID: connectionID,
      selectedConnectionProfileID: selection,
      updateConnectionProfile: { profile in
        context.store.updateAIConnectionProfile(profile)
      },
      createConnectionProfile: { name, preset in
        context.store.createAIConnectionProfile(named: name, preset: preset)
      },
      duplicateConnectionProfile: { connectionID in
        context.store.duplicateAIConnectionProfile(connectionID)
      },
      currentActionMessage: {
        context.store.ai.actionMessage
      },
      deleteConnectionProfile: { profileID in
        context.store.deleteAIConnectionProfile(profileID)
      },
      deletableConnectionProfiles: context.store.aiConnectionProfiles.filter {
        context.store.canDeleteAIConnectionProfile($0.id)
      },
      credentialStorageMode: context.store.ai.credentialStorageMode,
      tokenAvailability: connectionID == context.store.activeAIConnectionProfile.id
        ? context.store.ai.tokenAvailability
        : context.store.ai.keyAvailability(forConnectionProfileID: connectionID),
      isActionRunning: context.store.ai.isActionRunning,
      actionMessage: context.store.ai.actionMessage,
      dataSharingConsent: context.store.ai.dataSharingConsent(for: connection.config),
      shouldFocusAPIKey: context.healthDestination == .aiKey,
      healthNavigationRequestID: context.healthNavigationRequestID,
      navigationDestination: context.navigationDestination,
      navigationRequestID: context.navigationRequestID,
      selectedSubsection: context.selectedSubsection,
      saveAPIKey: { token in
        context.store.ai.saveAPIKey(token, connectionProfileID: connectionID)
      },
      deleteAPIKey: {
        context.store.ai.deleteAPIKey(connectionProfileID: connectionID)
      },
      refreshKeyAvailability: {
        context.store.ai.refreshKeyAvailability()
      },
      setCredentialStorageMode: { mode in
        context.store.ai.setCredentialStorageMode(mode)
      },
      testConnection: { probeCapabilities in
        await context.store.ai.testConnection(
          connectionProfileID: connectionID, probeCapabilities: probeCapabilities
        )
      },
      discoverModels: { connectionProfileID, config in
        try await context.store.ai.discoverModels(
          for: connectionProfileID,
          config: config
        )
      },
      setRemoteAIEnabled: { enabled in
        context.store.ai.setRemoteAIEnabled(enabled)
      },
      grantDataSharingConsent: {
        guard let config = context.store.aiConnectionProfile(for: connectionID)?.config else {
          return
        }
        context.store.ai.grantDataSharingConsent(for: config, enablingRemoteAI: false)
      },
      revokeDataSharingConsent: {
        context.store.ai.revokeDataSharingConsent(connectionProfileID: connectionID)
      },
      isCodexDataSharingConsentGranted: { accountStatus in
        context.store.ai.dataSharingConsent(
          for: connection.config,
          codexAccountStatus: accountStatus
        ).isGranted
      },
      grantCodexDataSharingConsent: { accountStatus in
        guard let config = context.store.aiConnectionProfile(for: connectionID)?.config,
          config.usesCodexAppServer
        else { return }
        context.store.ai.grantDataSharingConsent(
          for: config, enablingRemoteAI: true, codexAccountStatus: accountStatus
        )
      },
      openSiteAISettings: {
        context.selectSettingsDestination(.tab(.siteAI))
      }
    )
  }

  static func makeSite(context: SettingsContext) -> some View {
    AISiteSettingsView(
      activeProfileBinding: context.activeProfileBinding,
      connectionProfiles: context.store.aiConnectionProfiles,
      selectedConnectionProfileID: Binding(
        get: { context.store.activeAIConnectionProfile.id },
        set: { _ = context.store.selectAIConnectionProfile($0) }
      ),
      createConnectionProfile: { name, preset in
        context.store.createAIConnectionProfile(named: name, preset: preset)
      },
      duplicateConnectionProfile: { connectionID in
        context.store.duplicateAIConnectionProfileForActiveSite(connectionID)
      },
      currentActionMessage: {
        context.store.ai.actionMessage
      },
      writingStyleArticles: context.store.drafts.filter { draft in
        draft.belongs(toSiteProfileID: context.store.activeProfileID)
          && !draft.isPrivate
          && !draft.bodyMarkdown.trimmedForPublishing.isEmpty
      },
      writingStylePreview: context.store.aiWritingStylePreview,
      isWritingStyleExtractionRunning: context.store.isAIWritingStyleExtractionRunning,
      generateWritingStylePreview: { articleIDs in
        await context.store.generateAIWritingStyleProfile(exemplarArticleIDs: Array(articleIDs))
      },
      applyWritingStylePreview: { preview in
        context.store.applyAIWritingStyleProfile(preview)
      },
      discardWritingStylePreview: {
        context.store.discardAIWritingStyleProfilePreview()
      },
      openSharedConnectionSettings: {
        context.selectSettingsDestination(.ai(.connection))
      }
    )
  }
}

/// Editing selection belongs to this settings surface, not to the current site.
private struct AIConnectionManagerView: View {
  let context: SettingsContext
  @State private var selectedConnectionID: UUID?

  private var connectionID: UUID {
    if let selectedConnectionID,
      context.store.aiConnectionProfile(for: selectedConnectionID) != nil
    {
      return selectedConnectionID
    }
    return context.store.activeAIConnectionProfile.id
  }

  var body: some View {
    SettingsAITabFactory.makeEditor(
      context: context,
      connectionID: connectionID,
      selection: Binding(
        get: { connectionID },
        set: { selectedConnectionID = $0 }
      )
    )
    .id(connectionID)
    .onChange(of: context.navigationRequestID) { _, _ in
      selectedConnectionID = context.store.activeAIConnectionProfile.id
    }
    .onChange(of: context.healthNavigationRequestID) { _, _ in
      if context.healthDestination == .aiKey {
        selectedConnectionID = context.store.activeAIConnectionProfile.id
      }
    }
  }
}
