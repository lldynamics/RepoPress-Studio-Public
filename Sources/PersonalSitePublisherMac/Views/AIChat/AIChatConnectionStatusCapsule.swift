import SwiftUI

struct AIChatConnectionStatusCapsule: View {
  let statusSummary: String
  let statusDetail: String
  let isReady: Bool
  let isEnabled: Bool
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 5) {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)

        Text(statusSummary)
          .font(.workbenchMetadata.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)

        Image(systemName: "chevron.down")
          .font(.workbenchMetadata.weight(.bold))
          .foregroundStyle(.workbenchSecondary)
      }
      .padding(.horizontal, WorkbenchSpacing.control)
      .padding(.vertical, WorkbenchSpacing.tight)
      .background(statusColor.opacity(0.08), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .help(statusDetail)
    .accessibilityLabel(String(localized: "AI 连接与模型"))
    .accessibilityValue(statusDetail)
    .accessibilityIdentifier("ai-assistant-connection-status")
  }

  private var statusColor: Color {
    isReady ? WorkbenchTheme.success : WorkbenchTheme.warning
  }
}
