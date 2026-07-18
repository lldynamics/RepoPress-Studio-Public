import Foundation
import PublishingWorkbenchCore
import StoreKit
import SwiftUI

@MainActor
final class StoreKitProEntitlementCoordinator: ObservableObject {
  @Published private(set) var isBusy = false
  @Published private(set) var productDisplayPrice: String?
  @Published private(set) var purchaseTypeDisplayName: String?

  private let productID = MonetizationProductCatalog.proLifetimeProductID
  private var didStart = false
  private var transactionUpdatesTask: Task<Void, Never>?

  deinit {
    transactionUpdatesTask?.cancel()
  }

  func start(store: WorkbenchStore) {
    guard !didStart else {
      return
    }

    didStart = true
    transactionUpdatesTask = Task { [weak self, weak store] in
      guard let self, let store else {
        return
      }
      await self.refreshProductPresentation()
      await self.refreshCurrentEntitlements(store: store, reportsMissingEntitlement: false)
      await self.listenForTransactionUpdates(store: store)
    }
  }

  func purchasePro(store: WorkbenchStore) async {
    isBusy = true
    defer {
      isBusy = false
    }

    do {
      guard let product = try await Product.products(for: [productID]).first else {
        store.setMonetizationMessage("没有从 App Store 读取到 Pro 产品：\(productID)。")
        return
      }
      updateProductPresentation(product)

      let result = try await product.purchase()
      switch result {
      case .success(let verification):
        guard let transaction = try verifiedProTransaction(from: verification) else {
          store.setMonetizationMessage("购买完成，但返回的产品不是当前 Pro 项目。")
          return
        }
        store.applyVerifiedStoreKitEntitlement(productID: transaction.productID)
        await transaction.finish()
      case .pending:
        store.setMonetizationMessage("购买仍在等待 App Store 确认。")
      case .userCancelled:
        store.setMonetizationMessage("已取消购买。")
      @unknown default:
        store.setMonetizationMessage("购买返回了未知状态。")
      }
    } catch {
      store.setMonetizationMessage("购买失败：\(error.localizedDescription)")
    }
  }

  private func refreshProductPresentation() async {
    do {
      guard let product = try await Product.products(for: [productID]).first else { return }
      updateProductPresentation(product)
    } catch {
      productDisplayPrice = nil
      purchaseTypeDisplayName = nil
    }
  }

  private func updateProductPresentation(_ product: Product) {
    productDisplayPrice = product.displayPrice
    switch product.type {
    case .consumable:
      purchaseTypeDisplayName = "消耗型购买"
    case .nonConsumable:
      purchaseTypeDisplayName = "一次性购买"
    case .autoRenewable:
      purchaseTypeDisplayName = "自动续期订阅"
    case .nonRenewable:
      purchaseTypeDisplayName = "非续期订阅"
    default:
      purchaseTypeDisplayName = "App Store 购买"
    }
  }

  func restorePro(store: WorkbenchStore) async {
    isBusy = true
    defer {
      isBusy = false
    }

    do {
      try await AppStore.sync()
      await refreshCurrentEntitlements(store: store, reportsMissingEntitlement: true)
    } catch {
      store.setMonetizationMessage("恢复购买失败：\(error.localizedDescription)")
    }
  }

  private func refreshCurrentEntitlements(
    store: WorkbenchStore,
    reportsMissingEntitlement: Bool
  ) async {
    var foundProEntitlement = false

    for await entitlement in StoreKit.Transaction.currentEntitlements {
      do {
        guard let transaction = try verifiedProTransaction(from: entitlement) else {
          continue
        }
        store.applyVerifiedStoreKitEntitlement(productID: transaction.productID)
        foundProEntitlement = true
        break
      } catch {
        store.setMonetizationMessage("StoreKit 权限验证失败：\(error.localizedDescription)")
      }
    }

    if !foundProEntitlement {
      store.markProEntitlementCheckCompleted(
        foundEntitlement: false,
        message: reportsMissingEntitlement ? "没有找到可恢复的 Pro 购买。" : nil
      )
    }
  }

  private func listenForTransactionUpdates(store: WorkbenchStore) async {
    for await update in StoreKit.Transaction.updates {
      do {
        guard let transaction = try verifiedProTransaction(from: update) else {
          continue
        }
        store.applyVerifiedStoreKitEntitlement(productID: transaction.productID)
        await transaction.finish()
      } catch {
        store.setMonetizationMessage("StoreKit 交易更新验证失败：\(error.localizedDescription)")
      }
    }
  }

  private func verifiedProTransaction(
    from result: VerificationResult<StoreKit.Transaction>
  ) throws -> StoreKit.Transaction? {
    switch result {
    case .verified(let transaction):
      return transaction.productID == productID ? transaction : nil
    case .unverified(let transaction, let error):
      if transaction.productID == productID {
        throw error
      }
      return nil
    }
  }
}
