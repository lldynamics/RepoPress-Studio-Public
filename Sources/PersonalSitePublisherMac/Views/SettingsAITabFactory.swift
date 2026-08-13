import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsAITabFactory {
  static func make(context: SettingsContext) -> some View {
    AISettingsView(
      activeProfileBinding: context.activeProfileBinding,
      connectionProfiles: context.store.aiConnectionProfiles,
      selectedConnectionProfileID: Binding(
        get: { context.store.activeAIConnectionProfile.id },
        set: { context.store.selectAIConnectionProfile($0) }
      ),
      updateConnectionProfile: { profile in
        context.store.updateAIConnectionProfile(profile)
      },
      createConnectionProfile: { name, preset in
        context.store.createAIConnectionProfile(named: name, preset: preset)
      },
      deleteConnectionProfile: { profileID in
        context.store.deleteAIConnectionProfile(profileID)
      },
      deletableConnectionProfiles: context.store.aiConnectionProfiles.filter {
        context.store.canDeleteAIConnectionProfile($0.id)
      },
      credentialStorageMode: context.store.ai.credentialStorageMode,
      tokenAvailability: context.store.ai.tokenAvailability,
      isActionRunning: context.store.ai.isActionRunning,
      actionMessage: context.store.ai.actionMessage,
      dataSharingConsent: context.store.ai.dataSharingConsent,
      shouldFocusAPIKey: context.healthDestination == .aiKey,
      healthNavigationRequestID: context.healthNavigationRequestID,
      navigationDestination: context.navigationDestination,
      navigationRequestID: context.navigationRequestID,
      saveAPIKey: { token in
        context.store.ai.saveAPIKey(token)
      },
      deleteAPIKey: {
        context.store.ai.deleteAPIKey()
      },
      refreshKeyAvailability: {
        context.store.ai.refreshKeyAvailability()
      },
      setCredentialStorageMode: { mode in
        context.store.ai.setCredentialStorageMode(mode)
      },
      testConnection: { probeCapabilities in
        await context.store.ai.testConnection(probeCapabilities: probeCapabilities)
      },
      grantDataSharingConsent: {
        context.store.ai.grantDataSharingConsent()
      },
      revokeDataSharingConsent: {
        context.store.ai.revokeDataSharingConsent()
      }
    )
  }
}
