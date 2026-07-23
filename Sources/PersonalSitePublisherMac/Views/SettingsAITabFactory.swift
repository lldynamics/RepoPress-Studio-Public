import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsAITabFactory {
  static func make(context: SettingsContext) -> some View {
    AISettingsView(
      activeProfileBinding: context.activeProfileBinding,
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
      }
    )
  }
}
