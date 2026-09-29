import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

extension AIChatContextInspectorView {
  var conversationNavigationTitle: String {
    AIChatInspectorHeaderPresentation.conversationTitle(state.conversation?.conversationTitle)
  }

  var displayedGeneralConversation: AIConversation? {
    ai.generalChatConversation(withID: inspectorSurfaceConversationID)
      ?? ai.activeGeneralChatConversation
  }

  var selectedGeneralConnectionProfile: AIConnectionProfile? {
    guard let connectionProfileID = displayedGeneralConversation?.connectionProfileID else {
      return nil
    }
    return ai.chatConnectionProfiles.first { $0.id == connectionProfileID }
  }

  func refreshDisplayedGeneralKeyAvailability() {
    guard ai.chatContextMode == .general,
      let connection = selectedGeneralConnectionProfile
    else { return }
    generalKeyAvailabilityByConnectionID[connection.id] = ai.keyAvailability(
      forConnectionProfileID: connection.id
    )
  }

  var generalKeyAvailabilityRefreshKey: AIChatGeneralKeyAvailabilityRefreshKey {
    AIChatGeneralKeyAvailabilityRefreshKey(
      connectionProfileID: displayedGeneralConversation?.connectionProfileID,
      providerConfig: selectedGeneralConnectionProfile?.config,
      activeTokenAvailability: ai.tokenAvailability
    )
  }

  var currentAIProviderConfig: AIProviderConfig {
    if ai.chatContextMode == .general {
      return selectedGeneralConnectionProfile?.config ?? AIProviderConfig()
    }
    guard let draft = inspectorDraft else { return AIProviderConfig() }
    return ai.chatProviderConfig(for: draft)
  }

  var supportsSelectableReasoningLevel: Bool {
    if ai.chatContextMode == .general {
      guard let config = selectedGeneralConnectionProfile?.config,
        displayedGeneralConversation != nil
      else { return false }
      return AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
        config: config,
        hasDraft: true
      )
    }
    return AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
      config: currentAIProviderConfig,
      hasDraft: inspectorDraft != nil
    )
  }

  func localizedReasoningLevelTitle(_ level: AIChatReasoningLevel) -> String {
    switch level {
    case .quick:
      return String(localized: "快速")
    case .standard:
      return String(localized: "标准")
    case .deep:
      return String(localized: "深度")
    }
  }

  func localizedKnowledgePolicyTitle(_ policy: KnowledgeRetrievalPolicy) -> String {
    switch policy {
    case .off:
      return String(localized: "关闭资料库")
    case .automatic:
      return String(localized: "自动检索")
    case .pinnedOnly:
      return String(localized: "仅固定资料")
    }
  }

  func openAISettings() {
    SettingsNavigation.present(
      destination: .ai(.connection),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }

  func openAICredentialsSettings() {
    SettingsNavigation.present(
      destination: .ai(.credentials),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }

  var contextModeBinding: Binding<AIPublishingChatContextMode> {
    Binding(
      get: { ai.chatContextMode },
      set: { mode in
        guard mode != ai.chatContextMode, !isChatBusy else { return }
        ai.setChatContextMode(mode)
        synchronizeInspectorConversationForContextMode(mode)
      }
    )
  }

  var knowledgePolicyBinding: Binding<KnowledgeRetrievalPolicy> {
    Binding(
      get: {
        ai.chatContextMode == .general
          ? (displayedGeneralConversation?.knowledgePolicy ?? .automatic)
          : ai.chatKnowledgePolicy
      },
      set: {
        if ai.chatContextMode == .general {
          _ = ai.setGeneralChatKnowledgePolicy(
            $0,
            conversationID: displayedGeneralConversation?.id
          )
        } else {
          ai.setChatKnowledgePolicy($0)
        }
      }
    )
  }

}
