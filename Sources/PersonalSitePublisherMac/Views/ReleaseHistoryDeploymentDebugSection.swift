import PublishingWorkbenchCore
import SwiftUI

#if DEBUG
extension ReleaseHistoryDetailView {
  var deploymentAdvancedDebugSection: some View {
    DisclosureGroup {
      deploymentWebhookReceiverSection
        .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Label("高级调试", systemImage: "ladybug")
          .font(.headline)
        Text("本地 Webhook HTTP Receiver 和手动 JSON 注入，仅用于排查部署回调；日常发布使用上方轮询和单条记录的检查部署。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  var deploymentWebhookReceiverSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("本地 Webhook 调试")
            .font(.headline)
          Text("高级调试用：启动本地 HTTP 接收器或粘贴平台 Webhook JSON，写入最新发布记录的部署快照和历史。普通发布建议使用手动检查或部署轮询。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("平台", selection: $webhookProvider) {
          ForEach(DeploymentProvider.allCases) { provider in
            Text(provider.localizedDisplayName).tag(provider)
          }
        }
        .frame(width: 230)
        .accessibilityLabel("Webhook 平台")
        .accessibilityValue(webhookProvider.localizedDisplayName)
      }

      HStack(spacing: 8) {
        if store.deploymentWebhookHTTPReceiverState.isRunning {
          Button {
            store.stopDeploymentWebhookHTTPReceiver()
          } label: {
            Label("停止接收器", systemImage: "stop.circle")
          }
          .accessibilityLabel("停止 Webhook 接收器")
        } else {
          Button {
            store.startDeploymentWebhookHTTPReceiver()
          } label: {
            Label("启动本地接收器", systemImage: "dot.radiowaves.left.and.right")
          }
          .accessibilityLabel("启动本地 Webhook 接收器")
        }

        if let endpointURLText = store.deploymentWebhookHTTPReceiverState.endpointURLText {
          Button {
            copy(endpointURLText, message: "已复制 Webhook 接收地址。")
          } label: {
            Label("复制地址", systemImage: "doc.on.doc")
          }
          .accessibilityLabel("复制 Webhook 接收地址")
          Text(endpointURLText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        } else {
          Text(store.deploymentWebhookHTTPReceiverState.message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .controlSize(.small)

      TextEditor(text: $webhookPayloadText)
        .font(.caption.monospaced())
        .frame(minHeight: 88)
        .overlay(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .stroke(.quaternary, lineWidth: 1)
        )
        .accessibilityLabel("Webhook JSON 载荷")
        .accessibilityHint("粘贴平台回调内容后接收")

      HStack {
        Button {
          receiveDeploymentWebhook()
        } label: {
          Label("接收 Webhook", systemImage: "tray.and.arrow.down")
        }
        .disabled(webhookPayloadText.trimmedForPublishing.isEmpty || store.activeProfileReleaseRecords.isEmpty)

        Button {
          webhookPayloadText = ""
        } label: {
          Label("清空", systemImage: "xmark.circle")
        }
        .disabled(webhookPayloadText.isEmpty)

        Spacer()

        if store.activeProfileReleaseRecords.isEmpty {
          Text("没有可写入的发布记录。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let latestRecord = store.activeProfileReleaseRecords.first {
          Text("目标：\(latestRecord.title)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .controlSize(.small)
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  func receiveDeploymentWebhook() {
    guard let latestRecord = store.activeProfileReleaseRecords.first else {
      return
    }
    if store.receiveDeploymentWebhook(
      provider: webhookProvider,
      payloadText: webhookPayloadText,
      for: latestRecord
    ) != nil {
      webhookPayloadText = ""
    }
  }

}
#endif
