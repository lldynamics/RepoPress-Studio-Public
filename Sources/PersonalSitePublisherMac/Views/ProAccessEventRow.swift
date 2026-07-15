import PublishingWorkbenchCore
import SwiftUI

struct ProAccessEventRow: View {
  let event: MonetizationAccessEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Label(event.feature.localizedDisplayName, systemImage: event.outcome.systemImage)
          .font(.callout.weight(.medium))

        Spacer()

        Text(event.outcome.localizedDisplayName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(foreground)
      }

      Text(event.quotaSummary)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(event.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.vertical, 4)
  }

  private var foreground: Color {
    switch event.outcome {
    case .allowedFreeUse, .allowedProEntitlement:
      return .green
    case .blockedRequiresPro:
      return .orange
    }
  }
}
