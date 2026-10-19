import PublishingWorkbenchCore
import SwiftUI

/// Observe connection changes at the action, without invalidating the drawer.
struct PublishDrawerAIFixButton: View {
  let issue: PublishDrawerReadinessIssue
  let store: WorkbenchStore
  let isPrimaryAction: Bool
  let onRequestAIFix: () -> Void
  @ObservedObject private var aiActions: WorkbenchAIFeatureFacade
  @ObservedObject private var codexConnection = CodexConnectionController.shared
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction

  init(
    issue: PublishDrawerReadinessIssue, store: WorkbenchStore, isPrimaryAction: Bool = true,
    onRequestAIFix: @escaping () -> Void
  ) {
    self.issue = issue
    self.store = store
    self.isPrimaryAction = isPrimaryAction
    self.onRequestAIFix = onRequestAIFix
    _aiActions = ObservedObject(wrappedValue: store.ai)
  }

  private var config: AIProviderConfig {
    let profile =
      issue.draftID.flatMap { store.draft(for: $0) }.map { store.profile(for: $0) }
      ?? store.activeProfile
    return store.aiProviderConfig(for: profile)
  }

  private var configurationDestination: SettingsDestination? {
    guard let draftID = issue.draftID, let draft = store.draft(for: draftID) else { return nil }
    let profile = store.profile(for: draft)
    let availability =
      profile.aiConnectionProfileID.map {
        aiActions.keyAvailability(forConnectionProfileID: $0)
      } ?? aiActions.tokenAvailability
    return MarkdownEditorAIConfigurationPresentation.destination(
      for: config, isAIEnabled: !config.requiresAPIKey || availability.hasToken,
      hasAuthenticatedChatGPTAccount: codexConnection.accountStatus?.isAuthenticated == true)
  }

  var body: some View {
    let destination = configurationDestination
    let title = destination == nil ? String(localized: "AI 修复") : String(localized: "配置 AI 辅助")
    let button = Button {
      if let destination {
        SettingsNavigation.present(
          destination: destination, workspaceAction: settingsWorkspaceCommandAction
        ) { openSettings() }
      } else {
        onRequestAIFix()
      }
    } label: {
      Label(title, systemImage: destination == nil ? "sparkles" : "gearshape")
    }
    Group {
      if isPrimaryAction {
        button
          .buttonStyle(.bordered)
          .controlSize(.small)
      } else {
        button
          .buttonStyle(.link)
      }
    }
    .accessibilityLabel("\(title)：\(issue.title)")
    .accessibilityHint(
      destination == nil
        ? String(localized: "打开 AI 助手准备修复请求") : String(localized: "打开 AI 连接设置")
    )
    .accessibilityIdentifier("publish-readiness-ai-fix-\(issue.id)")
    .task(id: config.preset) {
      if config.preset == .codexAppServer { await codexConnection.refresh() }
    }
  }
}
