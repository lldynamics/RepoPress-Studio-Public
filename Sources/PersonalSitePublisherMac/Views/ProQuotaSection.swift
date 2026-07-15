import PublishingWorkbenchCore
import SwiftUI

struct ProQuotaSection: View {
  let aiUsed: Int
  let aiRemaining: Int
  let publishingUsed: Int
  let publishingRemaining: Int
  let batchUsed: Int
  let batchRemaining: Int

  var body: some View {
    Section("免费额度") {
      ProQuotaRow(
        title: PremiumFeature.aiRequest.localizedDisplayName,
        used: aiUsed,
        remaining: aiRemaining,
        systemImage: PremiumFeature.aiRequest.systemImage
      )
      ProQuotaRow(
        title: PremiumFeature.onlinePublishing.localizedDisplayName,
        used: publishingUsed,
        remaining: publishingRemaining,
        systemImage: PremiumFeature.onlinePublishing.systemImage
      )
      ProQuotaRow(
        title: PremiumFeature.batchPublishing.localizedDisplayName,
        used: batchUsed,
        remaining: batchRemaining,
        systemImage: PremiumFeature.batchPublishing.systemImage
      )
    }
  }
}
