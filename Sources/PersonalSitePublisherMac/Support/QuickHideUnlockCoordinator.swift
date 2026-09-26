import Foundation
import LocalAuthentication
import PublishingWorkbenchCore

@MainActor
enum QuickHideUnlockCoordinator {
  static let requiresAuthenticationKey = "quickHideRequiresDeviceAuthenticationV1"
  private static var isAuthenticating = false

  static var requiresAuthentication: Bool {
    UserDefaults.standard.bool(forKey: requiresAuthenticationKey)
  }

  static var isAvailable: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
  }

  /// Returns a message while keeping the mask in place when authentication fails.
  static func unlock(_ store: WorkbenchStore) async -> String? {
    guard store.isQuickHideActive else { return nil }
    guard requiresAuthentication else {
      store.deactivateQuickHide()
      return nil
    }
    guard !isAuthenticating else { return nil }

    let context = LAContext()
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
      return String(localized: "此 Mac 当前无法验证身份。请恢复 Touch ID 或登录密码后重试。")
    }

    isAuthenticating = true
    defer {
      context.invalidate()
      isAuthenticating = false
    }
    do {
      let approved = try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: String(localized: "解除 RepoPress Studio 的快速隐藏")
      )
      if approved && store.isQuickHideActive {
        store.deactivateQuickHide()
        return nil
      }
      return String(localized: "身份验证未通过，工作台仍保持隐藏。")
    } catch {
      return String(localized: "身份验证已取消或未通过，工作台仍保持隐藏。")
    }
  }
}
