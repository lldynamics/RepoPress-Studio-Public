import Foundation
@testable import PublishingWorkbenchCore

struct UnlockedTestProEntitlementProvider: ProEntitlementProviding {
  let productID: String

  init(productID: String = "test.pro") {
    self.productID = productID
  }

  func entitlement(restoring persistedEntitlement: ProEntitlementState) -> ProEntitlementState {
    ProEntitlementState(
      isUnlocked: true,
      source: .storeKit,
      productID: productID,
      unlockedAt: persistedEntitlement.unlockedAt ?? Date(),
      lastCheckedAt: Date()
    )
  }
}

@MainActor
extension WorkbenchStore {
  func applyUnlockedTestEntitlement(productID: String = "test.pro") {
    applyProEntitlement(from: UnlockedTestProEntitlementProvider(productID: productID))
  }
}
