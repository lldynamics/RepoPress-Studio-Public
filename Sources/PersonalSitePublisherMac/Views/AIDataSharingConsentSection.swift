import PublishingWorkbenchCore
import SwiftUI

struct AIDataSharingConsentSection: View {
  let presentation: AIDataSharingConsentPresentation
  let grantConsent: () -> Void
  let revokeConsent: () -> Void
  @State private var isRevocationConfirmationPresented = false

  var body: some View {
    Section("AI 数据发送授权") {
      if presentation.requiresConsent {
        LabeledContent("接收方", value: presentation.providerName)
        LabeledContent("发送地址") {
          Text(presentation.destination)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }

        Text("当你主动使用 AI 功能时，应用可能发送你的提示词、当前文章与站点上下文、选中的资料库片段，以及你主动添加的图片。服务商会按其隐私政策处理这些内容。")
          .font(.callout)

        if presentation.isGranted {
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
      } else {
        Label("本地 AI 服务", systemImage: "desktopcomputer")
          .foregroundStyle(WorkbenchTheme.success)
        Text("当前地址是本机回环地址。内容只发送给此 Mac 上运行的模型服务，不需要第三方数据发送授权。")
          .font(.callout)
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
