import PublishingWorkbenchCore
import SwiftUI

enum AIDataSharingConsentSectionMode: Equatable {
  case unconfigured
  case local
  case remote(isGranted: Bool)
  /// Codex account binding is managed by the live account section above. The
  /// generic consent section must not offer a status-less grant action.
  case codexManaged(hasDestinationGrant: Bool)

  init(
    presentation: AIDataSharingConsentPresentation,
    isCodexAppServer: Bool = false
  ) {
    switch presentation.destinationState {
    case .unconfigured:
      self = .unconfigured
    case .local:
      self = .local
    case .remote:
      self =
        isCodexAppServer
        ? .codexManaged(hasDestinationGrant: presentation.hasDestinationGrant)
        : .remote(isGranted: presentation.isGranted)
    }
  }
}

struct AIDataSharingConsentSection: View {
  let presentation: AIDataSharingConsentPresentation
  let isCodexAppServer: Bool
  let setRemoteAIEnabled: (Bool) -> Void
  let grantConsent: () -> Void
  let revokeConsent: () -> Void
  @State private var isRevocationConfirmationPresented = false

  init(
    presentation: AIDataSharingConsentPresentation,
    isCodexAppServer: Bool = false,
    setRemoteAIEnabled: @escaping (Bool) -> Void,
    grantConsent: @escaping () -> Void,
    revokeConsent: @escaping () -> Void
  ) {
    self.presentation = presentation
    self.isCodexAppServer = isCodexAppServer
    self.setRemoteAIEnabled = setRemoteAIEnabled
    self.grantConsent = grantConsent
    self.revokeConsent = revokeConsent
  }

  var body: some View {
    Section(String(localized: "AI 数据发送授权")) {
      Toggle("允许远程 AI", isOn: remoteAIEnabledBinding)
        .accessibilityIdentifier("settings-ai-remote-master-switch")
      Text(remoteAIEnabledDescription)
        .font(.callout)
        .foregroundStyle(presentation.isRemoteAIEnabled ? .secondary : WorkbenchTheme.warning)

      switch AIDataSharingConsentSectionMode(
        presentation: presentation,
        isCodexAppServer: isCodexAppServer
      ) {
      case .remote(let isGranted):
        remoteDestinationDetails

        if presentation.requiresAccountReauthorization {
          Label(
            "ChatGPT 账户已变化或尚未完成绑定；请重新登录并重新同意内容发送。",
            systemImage: "person.crop.circle.badge.exclamationmark"
          )
          .foregroundStyle(WorkbenchTheme.warning)
          Button("重新同意并启用此 AI 服务") {
            enableRemoteAIAndGrant()
          }
          .workbenchProminentActionStyle()
        } else if !presentation.isRemoteAIEnabled {
          Label(
            presentation.hasDestinationGrant
              ? "此服务已获授权，但远程 AI 总闸已关闭；重新开启后会恢复。"
              : "远程 AI 总闸已关闭；当前不会向此服务发送内容。",
            systemImage: "hand.raised.fill"
          )
          .foregroundStyle(WorkbenchTheme.warning)
          Button(
            presentation.hasDestinationGrant
              ? "重新启用此 AI 服务"
              : "同意并启用此 AI 服务"
          ) {
            enableRemoteAIAndGrant()
          }
          .workbenchProminentActionStyle()
        } else if isGranted {
          HStack {
            Label("已允许发送", systemImage: "checkmark.shield.fill")
              .foregroundStyle(WorkbenchTheme.success)
            Spacer()
            Button("撤销授权", role: .destructive) {
              isRevocationConfirmationPresented = true
            }
            .buttonStyle(.borderless)
          }
        } else {
          Label("尚未授权；测试连接和所有 AI 请求都会被阻止。", systemImage: "hand.raised.fill")
            .foregroundStyle(WorkbenchTheme.warning)

          Button("同意并启用此 AI 服务") {
            enableRemoteAIAndGrant()
          }
          .workbenchProminentActionStyle()
        }
      case .codexManaged(let hasDestinationGrant):
        remoteDestinationDetails
        Text("ChatGPT 账户绑定和重新同意由上方的 ChatGPT 账户区管理。")
          .font(.callout)
        if !presentation.isRemoteAIEnabled {
          Label(
            hasDestinationGrant
              ? "此目的地曾获授权，但远程 AI 总闸已关闭；当前不会发送内容。"
              : "远程 AI 总闸已关闭；当前不会向 ChatGPT 发送内容。",
            systemImage: "hand.raised.fill"
          )
          .foregroundStyle(WorkbenchTheme.warning)
        } else if hasDestinationGrant {
          Label(
            "已保存 ChatGPT 目的地授权；当前账户是否可用请以上方实时账户状态为准。",
            systemImage: "person.crop.circle.badge.checkmark"
          )
          .foregroundStyle(.secondary)
        } else {
          Label(
            "尚未绑定 ChatGPT 账户；请在上方账户区登录并重新同意。",
            systemImage: "person.crop.circle.badge.exclamationmark"
          )
          .foregroundStyle(WorkbenchTheme.warning)
        }

        if hasDestinationGrant {
          HStack {
            Spacer()
            Button("撤销授权", role: .destructive) {
              isRevocationConfirmationPresented = true
            }
            .buttonStyle(.borderless)
          }
        }
      case .local:
        Label("本地 AI 服务", systemImage: "desktopcomputer")
          .foregroundStyle(WorkbenchTheme.success)
        Text("当前地址是本机回环地址。内容只发送给此 Mac 上运行的模型服务，不需要第三方数据发送授权。")
          .font(.callout)
      case .unconfigured:
        Label(String(localized: "未配置发送地址"), systemImage: "gearshape")
          .foregroundStyle(WorkbenchTheme.warning)
        Text(
          String(localized: "请先配置 API 基础地址。配置完成后，应用会判断数据只发送到本机，还是需要第三方授权。")
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .confirmationDialog(
      "撤销 \(presentation.providerName) 的 AI 数据发送授权？",
      isPresented: $isRevocationConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("撤销授权", role: .destructive) {
        revokeConsent()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("撤销后，测试连接、AI 对话、写作建议和图片文案等功能都会停止发送请求，直到你再次明确同意。")
    }
  }

  /// Enables the application-level gate before writing the destination grant.
  /// Keeping this ordering local to the section prevents the old dead loop in
  /// which granting while the gate was explicitly disabled left the service
  /// unusable.
  func enableRemoteAIAndGrant() {
    setRemoteAIEnabled(true)
    grantConsent()
  }

  private var remoteAIEnabledBinding: Binding<Bool> {
    Binding(
      get: { presentation.isRemoteAIEnabled },
      set: { setRemoteAIEnabled($0) }
    )
  }

  private var remoteAIEnabledDescription: String {
    presentation.isRemoteAIEnabled
      ? String(localized: "远程 AI 总闸已开启；逐服务授权仍单独生效。关闭后不会发送远程请求，原有逐服务授权会保留。")
      : String(localized: "远程 AI 总闸已关闭；不会发送任何远程请求。逐服务授权会保留，重新开启后恢复；本地回环 AI 不受影响。")
  }

  @ViewBuilder
  private var remoteDestinationDetails: some View {
    Text("资料库中的“允许发送给远程 AI”是独立的逐条权限，默认关闭；只有资料权限和本处授权同时满足时，资料片段才会发送。")
      .font(.callout)
    LabeledContent("接收方", value: presentation.providerName)
    LabeledContent("发送地址") {
      Text(
        presentation.destination.isEmpty ? String(localized: "未配置发送地址") : presentation.destination
      )
      .font(.system(.body, design: .monospaced))
      .foregroundStyle(presentation.destination.isEmpty ? .secondary : .primary)
      .textSelection(.enabled)
    }
    Text("发送内容：当你主动使用 AI 功能时，应用可能发送你的提示词、当前文章与站点上下文、已允许发送的资料库片段，以及你主动添加的图片。服务商会按其隐私政策处理这些内容。")
      .font(.callout)
  }
}
