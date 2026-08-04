import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct AIProviderSection: View {
  let presetBinding: Binding<AIProviderPreset>
  let presetDisplayName: String
  let baseURL: Binding<String>
  let baseURLDisplayValue: String
  let model: Binding<String>
  let modelDisplayValue: String
  let requiresAPIKeyBinding: Binding<Bool>
  let requiresAPIKeyDisplayValue: String
  @State private var baseURLDraft: String

  init(
    presetBinding: Binding<AIProviderPreset>,
    presetDisplayName: String,
    baseURL: Binding<String>,
    baseURLDisplayValue: String,
    model: Binding<String>,
    modelDisplayValue: String,
    requiresAPIKeyBinding: Binding<Bool>,
    requiresAPIKeyDisplayValue: String
  ) {
    self.presetBinding = presetBinding
    self.presetDisplayName = presetDisplayName
    self.baseURL = baseURL
    self.baseURLDisplayValue = baseURLDisplayValue
    self.model = model
    self.modelDisplayValue = modelDisplayValue
    self.requiresAPIKeyBinding = requiresAPIKeyBinding
    self.requiresAPIKeyDisplayValue = requiresAPIKeyDisplayValue
    _baseURLDraft = State(initialValue: baseURL.wrappedValue)
  }

  var body: some View {
    Section {
      Picker(String(localized: "服务预设"), selection: presetBinding) {
        ForEach(AIProviderPreset.allCases) { preset in
          Text(preset.localizedDisplayName).tag(preset)
        }
      }
      .accessibilityLabel(String(localized: "AI 服务预设"))
      .accessibilityValue(presetDisplayName)

      baseURLField

      modelField

      Toggle(String(localized: "需要 API 密钥"), isOn: requiresAPIKeyBinding)
        .accessibilityLabel(String(localized: "AI 需要 API Key"))
        .accessibilityValue(requiresAPIKeyDisplayValue)

      if isPresetModifiedFromDefault {
        HStack {
          Spacer()
          Button(String(localized: "恢复为预设默认值")) {
            restorePresetDefaults()
          }
          .font(.caption)
          .buttonStyle(.borderless)
        }
      }
    } header: {
      Text(String(localized: "AI 服务配置"))
    } footer: {
      if presetBinding.wrappedValue == .custom {
        Text(String(localized: "自定义模式下，基础地址与模型默认为空。基础地址会在点击“应用地址”后生效，避免编辑过程中提前替换钥匙串凭据。"))
      }
    }
    .onChange(of: baseURL.wrappedValue) { _, newValue in
      baseURLDraft = newValue
    }
  }

  private var isPresetModifiedFromDefault: Bool {
    let preset = presetBinding.wrappedValue
    guard preset != .custom else { return false }
    return baseURLDraft != preset.defaultBaseURL
      || model.wrappedValue != preset.defaultModel
  }

  private var hasUnappliedBaseURL: Bool {
    baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      != baseURL.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var baseURLField: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .trailing) {
        TextField(
          String(localized: "API 基础地址"),
          text: $baseURLDraft
        )
        .padding(.trailing, 24)
        .textContentType(.URL)
        .accessibilityLabel(String(localized: "AI Base URL"))
        .accessibilityValue(baseURLDraft.nilIfEmpty ?? String(localized: "未填写"))

        if !baseURLDraft.trimmedForPublishing.isEmpty {
          Button {
            baseURLDraft = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help(String(localized: "清空 API 基础地址"))
          .accessibilityLabel(String(localized: "清空 AI Base URL"))
          .accessibilityIdentifier("ai-base-url-clear")
        }
      }

      HStack(spacing: 10) {
        Button(String(localized: "粘贴剪贴板地址")) {
          pasteBaseURLFromClipboard()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-base-url-paste")

        Button(String(localized: "恢复默认占位")) {
          restoreBaseURLPlaceholder()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-base-url-restore-default")
      }

      if hasUnappliedBaseURL {
        HStack(spacing: WorkbenchSpacing.control) {
          Label("地址修改尚未应用", systemImage: "pencil.and.outline")
            .font(.workbenchMetadata)
            .foregroundStyle(WorkbenchTheme.warning)

          Spacer(minLength: WorkbenchSpacing.control)

          Button("取消修改") {
            baseURLDraft = baseURL.wrappedValue
          }
          .controlSize(.small)

          Button("应用地址") {
            applyBaseURLDraft()
          }
          .workbenchProminentActionStyle()
          .controlSize(.small)
        }
      }
    }
  }

  private var modelField: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .trailing) {
        TextField(
          String(localized: "模型"),
          text: model
        )
        .padding(.trailing, 24)
        .accessibilityLabel(String(localized: "AI 模型"))
        .accessibilityValue(modelDisplayValue)

        if !model.wrappedValue.trimmedForPublishing.isEmpty {
          Button {
            model.wrappedValue = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help(String(localized: "清空模型名称"))
          .accessibilityLabel(String(localized: "清空 AI 模型"))
          .accessibilityIdentifier("ai-model-clear")
        }
      }

      HStack(spacing: 10) {
        Button(String(localized: "粘贴剪贴板模型")) {
          pasteModelFromClipboard()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-model-paste")

        Button(String(localized: "恢复默认占位")) {
          restoreModelPlaceholder()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-model-restore-default")
      }
    }
  }

  private func pasteBaseURLFromClipboard() {
    let value = NSPasteboard.general.string(forType: .URL)
      ?? NSPasteboard.general.string(forType: .string)
    guard let value, !value.trimmedForPublishing.isEmpty else { return }
    baseURLDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func pasteModelFromClipboard() {
    guard let value = NSPasteboard.general.string(forType: .string) else { return }
    let normalized = value
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    model.wrappedValue = normalized
  }

  private func restoreBaseURLPlaceholder() {
    baseURLDraft = presetBinding.wrappedValue.defaultBaseURL
  }

  private func restoreModelPlaceholder() {
    model.wrappedValue = presetBinding.wrappedValue.defaultModel
  }

  private func restorePresetDefaults() {
    let preset = presetBinding.wrappedValue
    baseURLDraft = preset.defaultBaseURL
    baseURL.wrappedValue = preset.defaultBaseURL
    model.wrappedValue = preset.defaultModel
    requiresAPIKeyBinding.wrappedValue = (preset != .local)
  }

  private func applyBaseURLDraft() {
    baseURL.wrappedValue = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    baseURLDraft = baseURL.wrappedValue
  }
}
