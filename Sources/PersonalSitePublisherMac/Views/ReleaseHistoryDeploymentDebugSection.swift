import PublishingWorkbenchCore
import SwiftUI

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
extension ReleaseHistoryDetailView {
  var deploymentAdvancedDebugSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("高级调试", systemImage: "ladybug")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text("本地 Webhook HTTP Receiver 和手动 JSON 注入，仅用于排查部署回调；日常发布使用上方轮询和单条记录的检查部署。")
        .font(.callout)
        .foregroundStyle(.secondary)

      deploymentWebhookReceiverSection
        .padding(.top, 8)
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-deployment-debug")
  }

  var deploymentWebhookReceiverSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("本地 Webhook 调试")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Text("高级调试用：启动本地 HTTP 接收器或粘贴平台 Webhook JSON，写入最新发布记录的部署快照和历史。普通发布建议使用手动检查或部署轮询。")
          .font(.callout)
          .foregroundStyle(.secondary)

        Picker("平台", selection: $webhookProvider) {
          ForEach(DeploymentProvider.allCases) { provider in
            Text(provider.localizedDisplayName).tag(provider)
          }
        }
        .frame(maxWidth: 230)
        .accessibilityLabel("Webhook 平台")
        .accessibilityValue(webhookProvider.localizedDisplayName)
        .accessibilityIdentifier("release-history-webhook-provider")
      }

      VStack(alignment: .leading, spacing: 8) {
        if store.deploymentWebhookHTTPReceiverState.isRunning {
          Button {
            store.stopDeploymentWebhookHTTPReceiver()
          } label: {
            Label("停止接收器", systemImage: "stop.circle")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityLabel("停止 Webhook 接收器")
          .accessibilityIdentifier("release-history-webhook-stop-receiver")
        } else {
          Button {
            store.startDeploymentWebhookHTTPReceiver()
          } label: {
            Label("启动本地接收器", systemImage: "dot.radiowaves.left.and.right")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityLabel("启动本地 Webhook 接收器")
          .accessibilityIdentifier("release-history-webhook-start-receiver")
        }

        if let endpointURLText = store.deploymentWebhookHTTPReceiverState.endpointURLText {
          Button {
            copy(endpointURLText, message: "已复制 Webhook 接收地址。")
          } label: {
            Label("复制地址", systemImage: "doc.on.doc")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityLabel("复制 Webhook 接收地址")
          .accessibilityIdentifier("release-history-webhook-copy-endpoint")
          Text(endpointURLText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(endpointURLText, lineLimit: 2)
        } else {
          Text(store.deploymentWebhookHTTPReceiverState.message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .controlSize(.regular)

      TextEditor(text: $webhookPayloadText)
        .font(.caption.monospaced())
        .frame(minHeight: 88)
        .overlay(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .stroke(.quaternary, lineWidth: 1)
        )
        .accessibilityLabel("Webhook JSON 载荷")
        .accessibilityHint("粘贴平台回调内容后接收")
        .accessibilityIdentifier("release-history-webhook-payload")

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 8)],
        alignment: .leading,
        spacing: 8
      ) {
        Button {
          receiveDeploymentWebhook()
        } label: {
          Label("接收 Webhook", systemImage: "tray.and.arrow.down")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(webhookPayloadText.trimmedForPublishing.isEmpty || store.activeProfileReleaseRecords.isEmpty)
        .accessibilityIdentifier("release-history-webhook-receive")

        Button {
          webhookPayloadText = ""
        } label: {
          Label("清空", systemImage: "xmark.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(webhookPayloadText.isEmpty)
        .accessibilityIdentifier("release-history-webhook-clear")
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)

      if store.activeProfileReleaseRecords.isEmpty {
        Text("没有可写入的发布记录。")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if let latestRecord = store.activeProfileReleaseRecords.first {
        let targetLabel = "目标：\(latestRecord.title)"
        Text(targetLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(targetLabel, lineLimit: 2)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-history-webhook-controls")
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
