import PublishingWorkbenchCore
import SwiftUI

struct LocalAIEngineDiscoverySection: View {
  let applyConfiguration: (_ baseURL: String, _ model: String) -> Bool

  @State private var results: [LocalAIEngineDiscoveryResult] = []
  @State private var selectedModels: [String: String] = [:]
  @State private var isDiscovering = false
  @State private var statusMessage: String?
  @State private var discoveryTask: Task<Void, Never>?

  var body: some View {
    Section {
      HStack(spacing: 10) {
        Button {
          startDiscovery()
        } label: {
          let title = results.isEmpty
            ? String(localized: "检测本地 AI")
            : String(localized: "重新检测本地 AI")
          Label(
            title,
            systemImage: "dot.radiowaves.left.and.right"
          )
        }
        .disabled(isDiscovering)
        .accessibilityHint("检测本机运行的 Ollama、LM Studio 和 vLLM 服务")

        if isDiscovering {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在检测本地 AI")

          Button("停止检测", role: .cancel) {
            cancelDiscovery()
          }
          .buttonStyle(.borderless)
        }

        Spacer(minLength: 0)
      }

      if results.isEmpty {
        Text(
          statusMessage
            ?? String(localized: "检测后可选择本机已有模型，并应用到当前 AI 连接档案。")
        )
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(results, id: \.kind) { result in
          engineRow(result)
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("本地 AI 发现")
    } footer: {
      Text("只检测本机回环地址。应用后当前连接将改为本地模式，不再要求 API Key。")
    }
    .onDisappear {
      discoveryTask?.cancel()
      discoveryTask = nil
      isDiscovering = false
    }
  }

  @ViewBuilder
  private func engineRow(_ result: LocalAIEngineDiscoveryResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(verbatim: result.kind.localizedTitle)
        } icon: {
          Image(systemName: engineSystemImage(result.kind))
        }
        .font(.subheadline.weight(.medium))

        Spacer(minLength: 8)

        Label(
          availabilityTitle(for: result),
          systemImage: result.isAvailable ? "checkmark.circle.fill" : "minus.circle"
        )
        .font(.caption)
        .foregroundStyle(
          result.isAvailable && !result.models.isEmpty
            ? WorkbenchTheme.success
            : Color.secondary
        )
      }

      Text(verbatim: result.baseURL)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if result.isAvailable, !result.models.isEmpty {
        Picker("模型", selection: selectedModelBinding(for: result)) {
          ForEach(result.models, id: \.self) { model in
            Text(model).tag(model)
          }
        }
        .accessibilityLabel("\(result.kind.localizedTitle) 模型")

        HStack {
          if !result.message.isEmpty {
            Text(verbatim: result.message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 8)

          Button("应用到当前连接") {
            if applyConfiguration(result.baseURL, selectedModel(for: result)) {
              statusMessage = String(
                format: String(localized: "已将 %@ 应用到当前连接。"),
                result.kind.localizedTitle
              )
            } else {
              statusMessage = String(localized: "连接未更新，请检查 Keychain 权限后重试。")
            }
          }
          .workbenchProminentActionStyle()
          .controlSize(.small)
          .disabled(selectedModel(for: result).isEmpty)
          .accessibilityHint("使用所选模型更新当前 AI 连接档案")
        }
      } else if !result.message.isEmpty {
        Text(verbatim: result.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private func startDiscovery() {
    discoveryTask?.cancel()
    isDiscovering = true
    statusMessage = nil

    discoveryTask = Task { @MainActor in
      let discovered = await LocalAIEngineDiscoveryService().discoverAll()
      guard !Task.isCancelled else { return }

      results = discovered
      synchronizeSelectedModels(with: discovered)
      isDiscovering = false
      discoveryTask = nil
      statusMessage = discovered.contains(where: \.isAvailable)
        ? String(localized: "本地 AI 检测完成。")
        : String(localized: "未发现正在运行的本地 AI 服务。")
    }
  }

  private func cancelDiscovery() {
    discoveryTask?.cancel()
    discoveryTask = nil
    isDiscovering = false
    statusMessage = String(localized: "已停止检测。")
  }

  private func synchronizeSelectedModels(with discovered: [LocalAIEngineDiscoveryResult]) {
    var updatedSelections: [String: String] = [:]
    for result in discovered where result.isAvailable && !result.models.isEmpty {
      let key = resultKey(result)
      let existing = selectedModels[key]
      updatedSelections[key] = existing.flatMap { result.models.contains($0) ? $0 : nil }
        ?? result.models.first
    }
    selectedModels = updatedSelections
  }

  private func selectedModelBinding(for result: LocalAIEngineDiscoveryResult) -> Binding<String> {
    let key = resultKey(result)
    return Binding(
      get: { selectedModels[key] ?? result.models.first ?? "" },
      set: { selectedModels[key] = $0 }
    )
  }

  private func selectedModel(for result: LocalAIEngineDiscoveryResult) -> String {
    selectedModels[resultKey(result)] ?? result.models.first ?? ""
  }

  private func resultKey(_ result: LocalAIEngineDiscoveryResult) -> String {
    "\(String(describing: result.kind))|\(result.baseURL)"
  }

  private func engineSystemImage(_ kind: LocalAIEngineKind) -> String {
    switch kind {
    case .ollama:
      return "shippingbox"
    case .lmStudio:
      return "desktopcomputer"
    case .vLLM:
      return "server.rack"
    }
  }

  private func availabilityTitle(for result: LocalAIEngineDiscoveryResult) -> String {
    if !result.isAvailable {
      return String(localized: "未检测到")
    }
    return result.models.isEmpty
      ? String(localized: "服务已响应")
      : String(localized: "可用")
  }
}
