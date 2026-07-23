import PublishingWorkbenchCore
import SwiftUI

struct ProSubscriptionSection: View {
  let isUnlocked: Bool
  let productDisplayPrice: String?
  let purchaseTypeDisplayName: String?
  let upgradeMessage: String

  var body: some View {
    Section(String(localized: "授权状态")) {
      Label(
        isUnlocked ? "Pro 已解锁" : "免费版",
        systemImage: isUnlocked ? "crown.fill" : "person"
      )
      .foregroundStyle(isUnlocked ? WorkbenchTheme.financeForeground : Color.secondary)

      if let productDisplayPrice, let purchaseTypeDisplayName {
        Label("\(productDisplayPrice) · \(purchaseTypeDisplayName)", systemImage: "cart")
          .font(.body.weight(.medium))
          .foregroundStyle(.secondary)
      } else {
        Text("价格与购买类型将在 App Store 产品加载后显示。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      Text(upgradeMessage)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
    }
  }
}
