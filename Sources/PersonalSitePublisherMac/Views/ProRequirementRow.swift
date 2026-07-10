import PublishingWorkbenchCore
import SwiftUI

struct ProRequirementRow: View {
  let requirement: ProUpgradeRequirement

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Label(requirement.feature.displayName, systemImage: requirement.feature.systemImage)
          .font(.callout.weight(.medium))

        Spacer()

        Label(
          requirement.isBlocking ? "需要 Pro" : "可用",
          systemImage: requirement.isBlocking ? "lock.fill" : "checkmark.circle"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(requirement.isBlocking ? Color.orange : Color.green)
      }

      Text(requirement.quotaSummary)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(requirement.reason)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(requirement.nextStep)
        .font(.caption)
        .foregroundStyle(requirement.isBlocking ? Color.orange : Color.secondary)
    }
    .padding(.vertical, 4)
  }
}
