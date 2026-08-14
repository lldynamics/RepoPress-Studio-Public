import PublishingWorkbenchCore
import SwiftUI

struct AIChatConnectionStatusCapsule: View {
  let ai: WorkbenchAIFeatureFacade
  @ObservedObject var chatState: WorkbenchAIChatFeatureFacade
  let draft: ArticleDraft?
  let open: () -> Void

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var pulse = false

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
    .disabled(draft == nil)
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
    guard let draft else { return AIProviderConfig() }
    return ai.chatProviderConfig(for: draft)
  }

  private var model: String {
    guard draft != nil else { return String(localized: "未选择") }
    return AIChatModelSelectionPresentationService.presentation(
      grade: ai.chatModelGrade,
      selectedModel: ai.chatSelectedModel,
      config: config
    ).activeModel.nilIfEmpty ?? String(localized: "未选择")
  }

  private var statusSummary: String {
    AIChatConnectionStatusPresentation.summary(
      for: config,
      activeModel: model,
      hasDraft: draft != nil
    )
  }

  private var isReady: Bool {
    AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: draft == nil ? nil : model,
      hasToken: ai.tokenAvailability.hasToken,
      hasDraft: draft != nil
    ).isReady
  }

  private var statusColor: Color {
    isReady ? WorkbenchTheme.success : WorkbenchTheme.warning
  }

  private var statusDetail: String {
    AIChatConnectionStatusPresentation.readiness(
      for: config,
      activeModel: draft == nil ? nil : model,
      hasToken: ai.tokenAvailability.hasToken,
      hasDraft: draft != nil
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
        .disabled(isTestingConnection || draft == nil)

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
    }
    .onChange(of: ai.chatModelGrade) { _, _ in
      connectionReport = nil
      synchronizeCustomModelInput()
    }
    .onChange(of: ai.chatSelectedModel) { _, _ in
      connectionReport = nil
      synchronizeCustomModelInput()
    }
    .onDisappear {
      isTestingConnection = false
    }
  }

  private var currentConfig: AIProviderConfig {
    guard let draft else { return ai.activeChatConnectionProfile.config }
    return ai.chatProviderConfig(for: draft)
  }

  private var currentSelection: AIChatModelSelectionPresentation? {
    guard draft != nil else { return nil }
    return AIChatModelSelectionPresentationService.presentation(
      grade: ai.chatModelGrade,
      selectedModel: ai.chatSelectedModel,
      config: currentConfig
    )
  }

  private var modelCandidates: [AIChatInspectorModelGradeCandidate] {
    guard draft != nil else { return [] }
    return AIChatInspectorHeaderPresentation.modelGradeCandidates(
      for: currentConfig,
      currentModel: ai.chatSelectedModel
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
      hasToken: ai.tokenAvailability.hasToken,
      hasDraft: draft != nil
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
        Text(AIChatInspectorHeaderPresentation.modelSummary(
          for: currentConfig,
          activeModel: currentSelection?.activeModel
        ))
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

  private var connectionProfilesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: "连接配置档案"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if ai.chatConnectionProfiles.isEmpty {
        Text(String(localized: "还没有可复用的连接档案。"))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(ai.chatConnectionProfiles) { profile in
          Button {
            ai.selectChatConnectionProfile(profile.id)
            connectionReport = nil
            synchronizeCustomModelInput()
          } label: {
            HStack(spacing: 9) {
              Image(systemName: ai.activeChatConnectionProfile.id == profile.id
                ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                  ai.activeChatConnectionProfile.id == profile.id
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
            ai.activeChatConnectionProfile.id == profile.id ? .isSelected : []
          )
        }
      }
    }
  }

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized: "模型档位"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(modelCandidates) { candidate in
        Button {
          ai.setChatModelGrade(candidate.grade)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: ai.chatModelGrade == candidate.grade
              ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(
                ai.chatModelGrade == candidate.grade ? WorkbenchTheme.primary : Color.secondary
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
        ai.setChatModelGrade(.custom)
      } label: {
        HStack(spacing: 9) {
          Image(systemName: ai.chatModelGrade == .custom
            ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(
              ai.chatModelGrade == .custom ? WorkbenchTheme.primary : Color.secondary
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

      Button {
        ai.resetChatModelToProfileDefault()
        synchronizeCustomModelInput()
      } label: {
        Label(String(localized: "恢复站点默认模型"), systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .padding(.top, 2)
    }
  }

  private func synchronizeCustomModelInput() {
    customModelInput = ai.chatSelectedModel.nilIfEmpty
      ?? currentSelection?.activeModel
      ?? ""
  }

  private func applyCustomModel() {
    let model = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return }
    customModelInput = model
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
