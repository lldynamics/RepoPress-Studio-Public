import PublishingWorkbenchCore
import SwiftUI

enum AIDataSharingConsentSectionMode: Equatable {
  case unconfigured
  case local
  case remote(isGranted: Bool)

  init(presentation: AIDataSharingConsentPresentation) {
    switch presentation.destinationState {
    case .unconfigured:
      self = .unconfigured
    case .local:
      self = .local
    case .remote:
      self = .remote(isGranted: presentation.isGranted)
    }
  }
}

struct AIDataSharingConsentSection: View {
  let presentation: AIDataSharingConsentPresentation
  let grantConsent: () -> Void
  let revokeConsent: () -> Void
  @State private var isRevocationConfirmationPresented = false

  var body: some View {
    Section("AI 数据发送授权") {
      switch AIDataSharingConsentSectionMode(presentation: presentation) {
      case .remote(let isGranted):
        Text("资料库中的“允许发送给远程 AI”是独立的逐条权限，默认关闭；只有资料权限和本处授权同时满足时，资料片段才会发送。")
          .font(.callout)
        LabeledContent("接收方", value: presentation.providerName)
        LabeledContent("发送地址") {
          Text(presentation.destination.isEmpty ? String(localized: "未配置发送地址") : presentation.destination)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(presentation.destination.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
        }

        Text("发送内容：当你主动使用 AI 功能时，应用可能发送你的提示词、当前文章与站点上下文、已允许发送的资料库片段，以及你主动添加的图片。服务商会按其隐私政策处理这些内容。")
          .font(.callout)

        if isGranted {
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
            grantConsent()
          }
          .workbenchProminentActionStyle()
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
}
