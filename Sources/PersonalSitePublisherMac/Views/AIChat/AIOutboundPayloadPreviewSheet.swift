import PublishingWorkbenchCore
import SwiftUI

/// Shows a content-free record of the most recent AI request for this
/// inspector surface. Remote requests are automatically redacted before they
/// are sent; this view deliberately has no per-request approval controls.
struct AIOutboundPayloadSummaryView: View {
  let scopeID: UUID
  @ObservedObject private var broker = AIOutboundPayloadApprovalBroker.shared

  var body: some View {
    EmptyView()
  }

  private func payloadSummary(_ preview: AIOutboundPayloadPreview) -> String {
    "\(preview.textCharacterCount) 字符、\(preview.imageCount) 张图片、\(preview.contextCounts.count) 类上下文"
  }
}
