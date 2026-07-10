import PublishingWorkbenchCore
import SwiftUI

struct ProRequirementsSection: View {
  let requirements: [ProUpgradeRequirement]

  var body: some View {
    Section("功能门槛") {
      ProRequirementsPlainContent(requirements: requirements, showsHeading: false)
    }
  }
}

struct ProRequirementsPlainContent: View {
  let requirements: [ProUpgradeRequirement]
  var showsHeading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsHeading {
        Label("功能门槛", systemImage: "lock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      ForEach(requirements) { requirement in
        ProRequirementRow(requirement: requirement)
      }
    }
  }
}
