import PublishingAICore
import SwiftUI

struct AIConnectionReconfiguration: Identifiable, Equatable {
  let id = UUID()
  let connectionID: UUID
  let connectionName: String
  let originalConfig: AIProviderConfig
  let proposedConfig: AIProviderConfig
  let referencingSites: [UUID: String]

  var invalidatesAPIKey: Bool {
    originalConfig.dataSharingConsentIdentifier != proposedConfig.dataSharingConsentIdentifier
  }

  func matches(
    selectedConnectionID: UUID,
    connection: AIConnectionProfile?,
    referencingSites: [UUID: String]
  ) -> Bool {
    selectedConnectionID == connectionID && connection?.id == connectionID
      && connection?.config == originalConfig && self.referencingSites == referencingSites
  }
}

enum AIConnectionReconfigurationResult: Equatable {
  case applied
  case failed
  case expired
}

/// Confirmation is a single-use snapshot. Cancel and expiry never invoke the
/// mutation, and the injected commit must check the same snapshot in live state.
struct AIConnectionReconfigurationState {
  var pending: AIConnectionReconfiguration?

  mutating func stage(
    connection: AIConnectionProfile,
    proposedConfig: AIProviderConfig,
    referencingSites: [UUID: String]
  ) {
    guard connection.config != proposedConfig else { return }
    pending = AIConnectionReconfiguration(
      connectionID: connection.id, connectionName: connection.name,
      originalConfig: connection.config, proposedConfig: proposedConfig,
      referencingSites: referencingSites
    )
  }

  mutating func cancel() { pending = nil }

  mutating func confirm(
    requestID: UUID,
    selectedConnectionID: UUID,
    connection: AIConnectionProfile?,
    referencingSites: [UUID: String],
    commit: (UUID, AIProviderConfig, AIProviderConfig, [UUID: String]) -> Bool
  ) -> AIConnectionReconfigurationResult {
    guard let request = pending, request.id == requestID else { return .expired }
    pending = nil
    guard
      request.matches(
        selectedConnectionID: selectedConnectionID, connection: connection,
        referencingSites: referencingSites
      )
    else { return .expired }
    return commit(
      request.connectionID, request.originalConfig, request.proposedConfig,
      request.referencingSites
    ) ? .applied : .failed
  }

  static func referencingSites(
    for connectionID: UUID, in sites: [(id: UUID, name: String, connectionID: UUID?)]
  ) -> [UUID: String] {
    Dictionary(
      uniqueKeysWithValues: sites.filter { $0.connectionID == connectionID }
        .map { ($0.id, $0.name) })
  }
}

struct AIConnectionReconfigurationConfirmation: View {
  let request: AIConnectionReconfiguration
  let onConfirm: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      Text("确认重配共享连接")
        .font(.workbenchTitle2.bold())
      Text("你正在修改“\(request.connectionName)”。以下站点会一起使用修改后的配置。")
        .fixedSize(horizontal: false, vertical: true)
      Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.content, verticalSpacing: 8) {
        GridRow {
          Text("配置").foregroundStyle(.workbenchSecondary)
          Text("当前").fontWeight(.semibold)
          Text("修改后").fontWeight(.semibold)
        }
        configurationRow(
          String(localized: "服务"), request.originalConfig.normalizedDisplayName,
          request.proposedConfig.normalizedDisplayName)
        configurationRow(
          String(localized: "地址"), request.originalConfig.normalizedBaseURL,
          request.proposedConfig.normalizedBaseURL)
        configurationRow(
          String(localized: "模型"), request.originalConfig.normalizedModel,
          request.proposedConfig.normalizedModel)
        configurationRow(
          String(localized: "需要 API Key"),
          request.originalConfig.requiresAPIKey ? String(localized: "开启") : String(localized: "关闭"),
          request.proposedConfig.requiresAPIKey ? String(localized: "开启") : String(localized: "关闭"))
      }
      .textSelection(.enabled)

      if request.originalConfig.baseURL != request.proposedConfig.baseURL
        || request.originalConfig.model != request.proposedConfig.model
      {
        Text("地址或模型将按上表替换；其他引用站点也会使用新的值。")
          .font(.workbenchBody)
      }
      if request.invalidatesAPIKey {
        Label("旧 API Key 将失效并从此连接移除；需要时请为新服务重新保存。", systemImage: "key.slash")
          .foregroundStyle(WorkbenchTheme.warning)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("引用站点：\(request.referencingSites.count) 个")
          .font(.workbenchHeadline)
        if request.referencingSites.isEmpty {
          Text("目前没有站点引用此连接。")
            .foregroundStyle(.workbenchSecondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(
                request.referencingSites.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self
              ) { id in
                Text(verbatim: request.referencingSites[id] ?? "")
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 120)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings-ai-reconfigure-sites")

      Text("想保留原连接时，可取消并新增独立连接。站点的连接选择不会自动改变。")
        .font(.workbenchBody).foregroundStyle(.workbenchSecondary)
      HStack {
        Spacer()
        Button("取消", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("settings-ai-reconfigure-cancel")
        Button("确认重配", role: .destructive, action: onConfirm)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("settings-ai-reconfigure-confirm")
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(width: 620)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-reconfigure-confirmation")
  }

  private func configurationRow(_ title: String, _ previous: String, _ proposed: String)
    -> some View
  {
    GridRow {
      Text(title).foregroundStyle(.workbenchSecondary)
      Text(previous.isEmpty ? String(localized: "未填写") : previous)
      Text(proposed.isEmpty ? String(localized: "未填写") : proposed)
    }
  }
}
