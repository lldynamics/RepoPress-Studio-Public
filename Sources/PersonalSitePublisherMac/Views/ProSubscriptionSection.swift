import PublishingWorkbenchCore
import SwiftUI

struct ProSubscriptionSection: View {
  let isUnlocked: Bool
  let productDisplayPrice: String?
  let purchaseTypeDisplayName: String?
  let upgradeMessage: String

  var body: some View {
    Section(String(localized: "Pro 会员与权限")) {
      Label(
        isUnlocked ? "Pro 终身会员已解锁" : "免费基础版",
        systemImage: isUnlocked ? "crown.fill" : "person"
      )
      .font(.headline)
      .foregroundStyle(isUnlocked ? WorkbenchTheme.financeForeground : Color.secondary)

      if let productDisplayPrice, let purchaseTypeDisplayName {
        Label("\(productDisplayPrice) · \(purchaseTypeDisplayName)", systemImage: "cart.fill")
          .font(.body.weight(.medium))
          .foregroundStyle(.secondary)
      } else {
        Text("价格与购买类型将在连接 App Store 后实时显示。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      Text(isUnlocked ? "您已拥有 RepoPress Pro 终身授权，感谢您对独立软件开发的大力支持！" : "一次性购买即可永久解锁 RepoPress Pro 终身权益，无任何隐形订阅。感谢您支持独立开发者持续维护与升级该软件。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
    }
  }
}
