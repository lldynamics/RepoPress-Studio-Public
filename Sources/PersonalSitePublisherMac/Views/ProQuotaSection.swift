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
    Section(String(localized: "每日免费额度")) {
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

      Text(String(localized: "每天按设备当前日期自动重置。"))
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(String(localized: "AI 使用你自己的服务商账户和 API Key，不计入应用免费额度。"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
