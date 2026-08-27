import PublishingWorkbenchCore
import SwiftUI

/// Shows a content-free record of the most recent AI request for this
/// inspector surface. Remote requests are automatically redacted before they
/// are sent; this view deliberately has no per-request approval controls.
struct AIOutboundPayloadSummaryView: View {
  let scopeID: UUID
  @ObservedObject private var broker = AIOutboundPayloadApprovalBroker.shared

  var body: some View {
    Group {
      if let preview = broker.lastPreview(for: scopeID) {
        Label(
          preview.isLoopback
            ? "最近本地 AI 请求摘要：\(payloadSummary(preview))"
            : "最近远程 AI 请求（已自动脱敏）：\(payloadSummary(preview))",
          systemImage: preview.isLoopback ? "desktopcomputer" : "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("ai-outbound-payload-summary")
      }
    }
  }

  private func payloadSummary(_ preview: AIOutboundPayloadPreview) -> String {
    "\(preview.textCharacterCount) 字符、\(preview.imageCount) 张图片、\(preview.contextCounts.count) 类上下文"
  }
}
