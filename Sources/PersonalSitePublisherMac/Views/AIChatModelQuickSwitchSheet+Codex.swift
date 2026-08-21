import PublishingWorkbenchCore
import SwiftUI

extension AIChatModelQuickSwitchSheet {
  var codexModelSection: some View {
    Group {
      Button(action: selectCodexConnectionDefault) {
        HStack(spacing: 9) {
          Image(
            systemName: isCodexConnectionDefaultSelected
              ? "checkmark.circle.fill" : "circle"
          )
          .foregroundStyle(
            isCodexConnectionDefaultSelected ? WorkbenchTheme.primary : Color.secondary
          )
          VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "跟随连接默认"))
              .font(.callout.weight(.medium))
            Text(String(localized: "使用 AI 设置中保存的默认模型"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(String(localized: "跟随连接默认模型"))
      .accessibilityValue(
        isCodexConnectionDefaultSelected ? String(localized: "已选择") : String(localized: "未选择")
      )

      if isLoadingCodexModels && codexModels.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(String(localized: "正在读取账户可用模型…"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel(String(localized: "正在读取账户可用模型"))
      } else if let codexModelsError, codexModels.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(codexModelsError)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Button {
            loadCodexModelsIfNeeded(force: true)
          } label: {
            Label(String(localized: "重新加载模型"), systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
      } else if codexModels.isEmpty {
        Text(String(localized: "暂未返回可用模型；仍可使用账户默认模型。"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(String(localized: "暂未返回可用模型，仍可使用账户默认模型"))
      } else {
        ForEach(codexModels, id: \.id) { model in
          Button {
            selectCodexModel(model)
          } label: {
            HStack(spacing: 9) {
              Image(
                systemName: isCodexModelSelected(model)
                  ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(
                isCodexModelSelected(model) ? WorkbenchTheme.primary : Color.secondary
              )
              VStack(alignment: .leading, spacing: 2) {
                Text(model.localizedDisplayName)
                  .font(.callout.weight(.medium))
                Text(model.model)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                if let description = model.description?.nilIfEmpty {
                  Text(description)
                    .font(.workbenchMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(model.localizedDisplayName)
          .accessibilityValue(
            isCodexModelSelected(model) ? String(localized: "已选择") : model.model
          )
          .help(model.description ?? model.model)
        }
      }

      if let codexModelsError, !codexModels.isEmpty {
        Label(codexModelsError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .textSelection(.enabled)
          .accessibilityLabel(
            String(format: String(localized: "刷新模型失败：%@"), codexModelsError)
          )
      }

      HStack {
        Button {
          loadCodexModelsIfNeeded(force: true)
        } label: {
          Label(String(localized: "刷新模型"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isLoadingCodexModels)
        .accessibilityLabel(String(localized: "刷新账户可用模型"))

        if isLoadingCodexModels && !codexModels.isEmpty {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(String(localized: "正在刷新模型"))
        }
      }

      codexReasoningEffortPicker
    }
  }

  private var codexReasoningEffortPicker: some View {
    Group {
      if let model = activeCodexModel, !model.supportedReasoningEfforts.isEmpty {
        Picker(String(localized: "思考等级"), selection: reasoningEffortBinding) {
          Text(String(localized: "跟随模型默认"))
            .tag("")
          ForEach(model.supportedReasoningEfforts, id: \.reasoningEffort) { effort in
            Text(effort.reasoningEffort)
              .tag(effort.reasoningEffort)
              .help(effort.description ?? effort.reasoningEffort)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(String(localized: "思考等级"))
        .accessibilityValue(reasoningEffortAccessibilityValue(for: model))
      } else if activeCodexModel != nil {
        Text(String(localized: "当前模型未提供可选思考等级，将使用模型默认设置。"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(String(localized: "当前模型未提供可选思考等级，将使用模型默认设置"))
      }
    }
  }

  private var isCodexConnectionDefaultSelected: Bool {
    guard currentConfig.usesCodexAppServer else { return false }
    let selected = currentSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return selected.isEmpty
  }

  private var activeCodexModel: CodexAppServerModel? {
    guard currentConfig.usesCodexAppServer else { return nil }
    let selected = currentSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModel = selected.isEmpty ? currentConfig.normalizedModel : selected
    if resolvedModel.isEmpty || resolvedModel == AIProviderPreset.codexDefaultModel {
      return codexModels.first(where: \.isDefault) ?? codexModels.first
    }
    return codexModels.first { model in
      model.model == resolvedModel || model.id == resolvedModel
    }
  }

  private var reasoningEffortBinding: Binding<String> {
    Binding(
      get: { chatState.chatReasoningEffortOverride ?? "" },
      set: { value in
        ai.setChatReasoningEffortOverride(value.nilIfEmpty)
      }
    )
  }

  private func reasoningEffortAccessibilityValue(for model: CodexAppServerModel) -> String {
    guard let effort = chatState.chatReasoningEffortOverride?.nilIfEmpty else {
      return String(localized: "跟随模型默认")
    }
    return model.supportedReasoningEfforts.first(where: {
      $0.reasoningEffort == effort
    })?.reasoningEffort ?? String(localized: "跟随模型默认")
  }

  private func isCodexModelSelected(_ model: CodexAppServerModel) -> Bool {
    guard !isCodexConnectionDefaultSelected else { return false }
    let selected = currentSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return selected == model.model || selected == model.id
  }

  private func selectCodexConnectionDefault() {
    if isGeneralMode {
      ai.setGeneralChatSelectedModel("")
      ai.setGeneralChatModelGrade(.standard)
    }
    ai.resetChatModelToProfileDefault()
    normalizeCodexReasoningEffort()
    synchronizeCustomModelInput()
  }

  private func selectCodexModel(_ model: CodexAppServerModel) {
    let selectedModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selectedModel.isEmpty else { return }
    if isGeneralMode {
      ai.setGeneralChatSelectedModel(selectedModel)
    }
    ai.setChatCustomModel(selectedModel)
    normalizeCodexReasoningEffort(for: model)
    synchronizeCustomModelInput()
  }

  func normalizeCodexReasoningEffort(for model: CodexAppServerModel? = nil) {
    guard currentConfig.usesCodexAppServer else { return }
    guard let model = model ?? activeCodexModel else { return }
    guard let override = chatState.chatReasoningEffortOverride?.nilIfEmpty else { return }
    let supported = model.supportedReasoningEfforts.contains {
      $0.reasoningEffort == override
    }
    if !supported {
      ai.setChatReasoningEffortOverride(nil)
    }
  }

  func loadCodexModelsIfNeeded(force: Bool = false) {
    guard currentConfig.usesCodexAppServer else {
      codexModels = []
      codexModelsError = nil
      isLoadingCodexModels = false
      return
    }
    guard force || codexModels.isEmpty, !isLoadingCodexModels else { return }

    isLoadingCodexModels = true
    codexModelsError = nil
    let profileID = chatState.activeChatConnectionProfile.id
    Task {
      do {
        let models = try await CodexAppServerClient.shared.models(includeHidden: false)
        guard !Task.isCancelled else { return }
        guard chatState.activeChatConnectionProfile.id == profileID,
          currentConfig.usesCodexAppServer
        else { return }
        codexModels = models.filter {
          !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        isLoadingCodexModels = false
        normalizeCodexReasoningEffort()
      } catch {
        guard !Task.isCancelled else { return }
        guard chatState.activeChatConnectionProfile.id == profileID else { return }
        codexModelsError =
          error.localizedDescription.nilIfEmpty
          ?? String(localized: "读取账户可用模型失败，请稍后重试。")
        isLoadingCodexModels = false
      }
    }
  }
}
