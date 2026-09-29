import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

struct AIChatConnectionStatusCapsule: View {
  let ai: WorkbenchAIFeatureFacade
  @ObservedObject var chatState: WorkbenchAIChatFeatureFacade
  @ObservedObject var codexConnection = CodexConnectionController.shared
  let draft: ArticleDraft?
  let open: () -> Void

  private var isGeneralMode: Bool {
    ai.chatContextMode == .general || draft == nil
  }

  private var displayedGeneralConversation: AIConversation? {
    ai.activeGeneralChatConversation
  }

  private var selectedGeneralConnectionProfile: AIConnectionProfile? {
    guard let connectionProfileID = displayedGeneralConversation?.connectionProfileID else {
      return nil
    }
    return ai.chatConnectionProfiles.first { $0.id == connectionProfileID }
  }

  var body: some View {
    Button(action: open) {
      HStack(spacing: 6) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)

        Text(statusSummary)
          .font(.caption.weight(.semibold))
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)

        Image(systemName: "chevron.down")
          .font(.workbenchMetadata.weight(.bold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(statusColor.opacity(0.10), in: Capsule())
      .overlay(Capsule().stroke(statusColor.opacity(0.20), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(draft == nil && ai.chatContextMode != .general)
    .help(statusSummary + "\n" + statusDetail)
    .accessibilityLabel(String(localized: "AI 连接与模型"))
    .accessibilityValue(statusDetail)
    .accessibilityIdentifier("ai-assistant-connection-status")
  }

  private var config: AIProviderConfig {
    if isGeneralMode {
      return ai.activeGeneralChatProviderConfig ?? chatState.activeChatConnectionProfile.config
    }
    guard let draft else { return AIProviderConfig() }
    return chatState.chatProviderConfig(for: draft)
  }

  private var model: String {
    if isGeneralMode {
      if let selected = displayedGeneralConversation?.selectedModel.nilIfEmpty {
        return selected
      }
      let grade = displayedGeneralConversation?.modelGrade ?? chatState.chatModelGrade
      return AIChatModelSelectionPresentationService.presentation(
        grade: grade,
        selectedModel: "",
        config: config
      ).activeModel.nilIfEmpty ?? String(localized: "未选择")
    }
    guard draft != nil else { return String(localized: "未选择") }
    return AIChatModelSelectionPresentationService.presentation(
      grade: chatState.chatModelGrade,
      selectedModel: chatState.chatSelectedModel,
      config: config
    ).activeModel.nilIfEmpty ?? String(localized: "未选择")
  }

  private var statusSummary: String {
    AIChatConnectionStatusPresentation.summary(
      for: config,
      activeModel: model,
      hasDraft: draft != nil || isGeneralMode
    )
  }

  private var isReady: Bool {
    let apiReadiness = AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: (draft == nil && !isGeneralMode) ? nil : model,
      hasToken: hasToken,
      hasDraft: draft != nil || isGeneralMode
    ).isReady
    return apiReadiness
      && (!config.usesCodexAppServer
        || (codexConnection.phase.isReady
          && !codexConnection.isChecking
          && !codexConnection.isPreparing))
  }

  private var hasToken: Bool {
    if isGeneralMode, let connection = selectedGeneralConnectionProfile {
      return ai.keyAvailability(forConnectionProfileID: connection.id).hasToken
    }
    return chatState.tokenAvailability.hasToken
  }

  private var statusColor: Color {
    isReady ? WorkbenchTheme.success : WorkbenchTheme.warning
  }

  private var statusDetail: String {
    if config.usesCodexAppServer,
      let presentation = AIChatCodexConnectionPresentation.configuration(
        phase: codexConnection.phase,
        progress: codexConnection.progress,
        failure: codexConnection.failure
      )
    {
      return presentation.detail
    }
    return AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: (draft == nil && !isGeneralMode) ? nil : model,
      hasToken: hasToken,
      hasDraft: draft != nil || isGeneralMode
    ).detail
  }

}
