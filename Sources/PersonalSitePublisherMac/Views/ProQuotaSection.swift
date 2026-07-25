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
    Section(String(localized: "免费版功能限制")) {
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

      Text(String(localized: "每日试用额度随系统日期自动重置；购买 Pro 终身会员可彻底解除上述限制。"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
