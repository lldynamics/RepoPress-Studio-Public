import PublishingWorkbenchCore
import SwiftUI

struct AIChatConnectionStatusCapsule: View {
  let ai: WorkbenchAIFeatureFacade
  @ObservedObject var chatState: WorkbenchAIChatFeatureFacade
  let draft: ArticleDraft?
  let open: () -> Void

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var pulse = false

  private var isGeneralMode: Bool {
    ai.chatContextMode == .general || draft == nil
  }

  private var displayedGeneralConversation: AIConversation? {
    ai.activeGeneralChatConversation
  }

  var body: some View {
    Button(action: open) {
      HStack(spacing: 6) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
          .scaleEffect(pulse && isReady ? 1.18 : 1)
          .opacity(pulse && isReady ? 0.72 : 1)

        Text(statusSummary)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)

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
    .help(statusDetail)
    .accessibilityLabel(String(localized: "AI 连接与模型"))
    .accessibilityValue(statusDetail)
    .accessibilityIdentifier("ai-assistant-connection-status")
    .onAppear {
      guard isReady, !accessibilityReduceMotion else { return }
      withAnimation(WorkbenchMotion.ambientPulse) {
        pulse = true
      }
    }
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
    AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: (draft == nil && !isGeneralMode) ? nil : model,
      hasToken: chatState.tokenAvailability.hasToken,
      hasDraft: draft != nil || isGeneralMode
    ).isReady
  }

  private var statusColor: Color {
    isReady ? WorkbenchTheme.success : WorkbenchTheme.warning
  }

  private var statusDetail: String {
    AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: (draft == nil && !isGeneralMode) ? nil : model,
      hasToken: chatState.tokenAvailability.hasToken,
      hasDraft: draft != nil || isGeneralMode
    ).detail
  }
}

struct AIChatModelQuickSwitchSheet: View {
  let ai: WorkbenchAIFeatureFacade
  @ObservedObject var chatState: WorkbenchAIChatFeatureFacade
  let draft: ArticleDraft?

  @Environment(\.dismiss) private var dismiss
  @State private var customModelInput = ""
  @State private var connectionReport: AIConnectionTestReport?
  @State private var isTestingConnection = false
  @State var codexModels: [CodexAppServerModel] = []
  @State var isLoadingCodexModels = false
  @State var codexModelsError: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(String(localized: "AI 快捷切换"), systemImage: "cpu")
          .font(.headline)
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "关闭 AI 快捷切换"))
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          connectionStatusCard
          connectionProfilesSection
          modelSection
        }
        .padding(18)
      }

      Divider()

      HStack {
        Button {
          testConnection()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "network")
              .symbolVariant(isTestingConnection ? .fill : .none)
              .workbenchAIThinkingSymbolEffect(isActive: isTestingConnection)
            Text(
              isTestingConnection
                ? String(localized: "测试中…")
                : String(localized: "测试连接")
            )
          }
        }
        .disabled(isTestingConnection)

        Spacer()

        Button(String(localized: "完成")) {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
    }
    .frame(minWidth: 470, minHeight: 520)
    .workbenchGlassContainer(material: .regularMaterial)
    .onAppear {
      synchronizeCustomModelInput()
      loadCodexModelsIfNeeded()
    }
    .onChange(of: chatState.chatModelGrade) { _, _ in
      connectionReport = nil
      synchronizeCustomModelInput()
    }
    .onChange(of: chatState.chatSelectedModel) { _, _ in
      connectionReport = nil
      synchronizeCustomModelInput()
      normalizeCodexReasoningEffort()
    }
    .onChange(of: chatState.activeChatConnectionProfile.id) { _, _ in
      codexModels = []
      codexModelsError = nil
      loadCodexModelsIfNeeded()
    }
    .onDisappear {
      isTestingConnection = false
    }
  }

  var isGeneralMode: Bool {
    ai.chatContextMode == .general || draft == nil
  }

  var displayedGeneralConversation: AIConversation? {
    ai.activeGeneralChatConversation
  }

  var currentConfig: AIProviderConfig {
    if isGeneralMode {
      return ai.activeGeneralChatProviderConfig ?? chatState.activeChatConnectionProfile.config
    }
    guard let draft else { return chatState.activeChatConnectionProfile.config }
    return chatState.chatProviderConfig(for: draft)
  }

  var currentGrade: AIChatModelGrade {
    if isGeneralMode {
      return displayedGeneralConversation?.modelGrade ?? chatState.chatModelGrade
    }
    return chatState.chatModelGrade
  }

  var currentSelectedModel: String {
    if isGeneralMode {
      return displayedGeneralConversation?.selectedModel ?? chatState.chatSelectedModel
    }
    return chatState.chatSelectedModel
  }

  private var currentSelection: AIChatModelSelectionPresentation? {
    return AIChatModelSelectionPresentationService.presentation(
      grade: currentGrade,
      selectedModel: currentSelectedModel,
      config: currentConfig
    )
  }

  private var modelCandidates: [AIChatInspectorModelGradeCandidate] {
    return AIChatInspectorHeaderPresentation.modelGradeCandidates(
      for: currentConfig,
      currentModel: currentSelectedModel
    )
  }

  private var connectionStatusColor: Color {
    if connectionReport != nil { return WorkbenchTheme.success }
    return currentReadiness.isReady ? WorkbenchTheme.success : WorkbenchTheme.warning
  }

  private var connectionStatusTitle: String {
    if let connectionReport { return connectionReport.headline }
    return currentReadiness.title
  }

  private var currentReadiness: AIChatConnectionReadiness {
    AIChatConnectionStatusPresentation.readiness(
      for: currentConfig,
      activeModel: currentSelection?.activeModel,
      hasToken: chatState.tokenAvailability.hasToken,
      hasDraft: draft != nil || isGeneralMode
    )
  }

  private var connectionStatusCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Circle()
          .fill(connectionStatusColor)
          .frame(width: 9, height: 9)
        Text(connectionStatusTitle)
          .font(.callout.weight(.semibold))
        Spacer()
        Text(
          AIChatInspectorHeaderPresentation.modelSummary(
            for: currentConfig,
            activeModel: currentSelection?.activeModel
          )
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }

      Text(connectionReport?.detailText ?? connectionDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(connectionReport == nil ? 2 : 4)
        .textSelection(.enabled)
    }
    .padding(12)
    .background(connectionStatusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(connectionStatusColor.opacity(0.18), lineWidth: 1)
    )
  }

  private var connectionDetail: String {
    if currentConfig.normalizedBaseURL.isEmpty {
      return String(localized: "当前连接档案没有 Base URL，点击下方档案即可快速切换到已配置服务。")
    }
    return String(localized: "Endpoint：") + currentConfig.normalizedBaseURL
  }

  private var activeConnectionProfileID: UUID {
    if isGeneralMode {
      return displayedGeneralConversation?.connectionProfileID
        ?? chatState.activeChatConnectionProfile.id
    }
    return chatState.activeChatConnectionProfile.id
  }

  private var connectionProfilesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: "连接配置档案"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if chatState.chatConnectionProfiles.isEmpty {
        Text(String(localized: "还没有可复用的连接档案。"))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(chatState.chatConnectionProfiles) { profile in
          Button {
            if isGeneralMode {
              ai.setGeneralChatConnectionProfile(profile.id)
            }
            ai.selectChatConnectionProfile(profile.id)
            connectionReport = nil
            synchronizeCustomModelInput()
          } label: {
            HStack(spacing: 9) {
              Image(
                systemName: activeConnectionProfileID == profile.id
                  ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(
                activeConnectionProfileID == profile.id
                  ? WorkbenchTheme.primary : Color.secondary
              )
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                  .font(.callout.weight(.medium))
                Text(profile.summary)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(
            activeConnectionProfileID == profile.id ? .isSelected : []
          )
        }
      }
    }
  }

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        currentConfig.usesCodexAppServer
          ? String(localized: "模型与思考等级")
          : String(localized: "模型档位")
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)

      if currentConfig.usesCodexAppServer {
        codexModelSection
      } else {
        standardModelSection
      }

      if !currentConfig.usesCodexAppServer {
        Button {
          if isGeneralMode {
            ai.setGeneralChatModelGrade(.standard)
            ai.setGeneralChatSelectedModel("")
          }
          ai.resetChatModelToProfileDefault()
          synchronizeCustomModelInput()
        } label: {
          Label(String(localized: "恢复默认模型"), systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.top, 2)
      }
    }
  }

  private var standardModelSection: some View {
    Group {
      ForEach(modelCandidates) { candidate in
        Button {
          if isGeneralMode {
            ai.setGeneralChatModelGrade(candidate.grade)
            ai.setGeneralChatSelectedModel("")
          }
          ai.setChatModelGrade(candidate.grade)
        } label: {
          HStack(spacing: 9) {
            Image(
              systemName: isGradeCandidateSelected(candidate)
                ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(
              isGradeCandidateSelected(candidate)
                ? WorkbenchTheme.primary : Color.secondary
            )
            VStack(alignment: .leading, spacing: 2) {
              Text(candidate.title)
                .font(.callout.weight(.medium))
              Text(candidate.model)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      Button {
        synchronizeCustomModelInput()
        if isGeneralMode {
          ai.setGeneralChatModelGrade(.custom)
        }
        ai.setChatModelGrade(.custom)
      } label: {
        HStack(spacing: 9) {
          Image(
            systemName: currentGrade == .custom
              ? "checkmark.circle.fill" : "circle"
          )
          .foregroundStyle(
            currentGrade == .custom
              ? WorkbenchTheme.primary : Color.secondary
          )
          Text(String(localized: "自定义模型"))
            .font(.callout.weight(.medium))
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if AIChatInspectorHeaderPresentation.showsCustomModelInput(selection: currentSelection) {
        HStack(spacing: 8) {
          TextField(String(localized: "输入模型名"), text: $customModelInput)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(String(localized: "自定义模型名称"))
            .onSubmit(applyCustomModel)
          Button(String(localized: "应用"), action: applyCustomModel)
            .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  private func isGradeCandidateSelected(_ candidate: AIChatInspectorModelGradeCandidate) -> Bool {
    currentGrade == candidate.grade && (currentSelectedModel.isEmpty || candidate.grade == .custom)
  }

  // Shared with the Codex extension so selecting the account default can keep
  // the existing custom-model field in sync without duplicating state logic.
  func synchronizeCustomModelInput() {
    customModelInput =
      currentSelectedModel.nilIfEmpty
      ?? currentSelection?.activeModel
      ?? ""
  }

  private func applyCustomModel() {
    let model = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return }
    customModelInput = model
    if isGeneralMode {
      ai.setGeneralChatSelectedModel(model)
    }
    ai.setChatCustomModel(model)
  }

  private func testConnection() {
    guard draft != nil else { return }
    isTestingConnection = true
    Task {
      let report = await ai.testConnection()
      guard !Task.isCancelled else { return }
      connectionReport = report
      isTestingConnection = false
    }
  }
}
