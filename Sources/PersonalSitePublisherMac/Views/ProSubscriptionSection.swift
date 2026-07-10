import PublishingWorkbenchCore
import SwiftUI

struct ProSubscriptionSection: View {
  let isUnlocked: Bool
  let productID: String?
  let upgradeMessage: String

  var body: some View {
    Section("订阅状态") {
      Label(
        isUnlocked ? "Pro 已解锁" : "免费版",
        systemImage: isUnlocked ? "crown.fill" : "person"
      )
      .foregroundStyle(isUnlocked ? .yellow : .secondary)

      Text("产品：\(productID ?? MonetizationProductCatalog.proLifetimeProductID)")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(upgradeMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
