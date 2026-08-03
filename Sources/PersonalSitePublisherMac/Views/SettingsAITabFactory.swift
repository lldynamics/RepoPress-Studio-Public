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
      canDeleteSelectedConnectionProfile: context.store.canDeleteAIConnectionProfile(
        context.store.activeAIConnectionProfile.id
      ),
      tokenAvailability: context.store.ai.tokenAvailability,
      isActionRunning: context.store.ai.isActionRunning,
      actionMessage: context.store.ai.actionMessage,
      dataSharingConsent: context.store.ai.dataSharingConsent,
      shouldFocusAPIKey: context.healthDestination == .aiKey,
      navigationRequestID: context.healthNavigationRequestID,
      saveAPIKey: { token in
        context.store.ai.saveAPIKey(token)
      },
      deleteAPIKey: {
        context.store.ai.deleteAPIKey()
      },
      refreshKeyAvailability: {
        context.store.ai.refreshKeyAvailability()
      },
      testConnection: {
        await context.store.ai.testConnection()
      },
      grantDataSharingConsent: {
        context.store.ai.grantDataSharingConsent()
      },
      revokeDataSharingConsent: {
        context.store.ai.revokeDataSharingConsent()
      },
      selectedDraftTitle: context.store.selectedDraft?.title,
      appendLocalWhisperTranscript: { transcript in
        context.store.appendLocalWhisperTranscript(transcript)
      }
    )
  }
}
