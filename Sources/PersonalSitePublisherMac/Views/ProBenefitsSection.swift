import PublishingWorkbenchCore
import SwiftUI

struct ProBenefitsSection: View {
  var body: some View {
    Section {
      DisclosureGroup("查看全部 Pro 权益") {
        ForEach(DistributionFeaturePolicy.visiblePremiumFeatures, id: \.id) { feature in
          Label(feature.proBenefit, systemImage: feature.systemImage)
        }
      }
    }
  }
}
