import Combine
import Foundation
import LocalAuthentication
import PublishingWorkbenchCore

/// The latest unlock failure, shared so the overlay can explain a failed
/// attempt started from the menu or keyboard shortcut.
@MainActor
final class QuickHideUnlockFeedback: ObservableObject {
  static let shared = QuickHideUnlockFeedback()
  @Published var message: String?
}

@MainActor
enum QuickHideUnlockCoordinator {
  static let requiresAuthenticationKey = "quickHideRequiresDeviceAuthenticationV1"
  /// Set while an authentication-protected mask is showing, so quitting and
  /// relaunching does not bypass the Touch ID / password requirement.
  static let wasActiveAtLastRunKey = "quickHideWasActiveWithAuthenticationV1"
  private static var isAuthenticating = false

  /// Called while the mask is visible.
  static func rememberActiveMaskIfNeeded() {
    guard requiresAuthentication else { return }
    UserDefaults.standard.set(true, forKey: wasActiveAtLastRunKey)
  }

  /// Re-applies an authentication-protected mask that was showing at quit.
  static func restoreMaskIfNeeded(_ store: WorkbenchStore) {
    guard UserDefaults.standard.bool(forKey: wasActiveAtLastRunKey) else { return }
    guard requiresAuthentication else {
      UserDefaults.standard.removeObject(forKey: wasActiveAtLastRunKey)
      return
    }
    store.activateQuickHide(reason: String(localized: "上次退出时工作台处于快速隐藏状态，请验证身份后继续。"))
  }

  /// Unlocks and publishes any failure to the shared overlay feedback.
  static func unlockAndReport(_ store: WorkbenchStore) async {
    QuickHideUnlockFeedback.shared.message = nil
    QuickHideUnlockFeedback.shared.message = await unlock(store)
  }

  private static func deactivate(_ store: WorkbenchStore) {
    store.deactivateQuickHide()
    UserDefaults.standard.removeObject(forKey: wasActiveAtLastRunKey)
    QuickHideUnlockFeedback.shared.message = nil
  }

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
      deactivate(store)
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
        deactivate(store)
        return nil
      }
      return String(localized: "身份验证未通过，工作台仍保持隐藏。")
    } catch {
      return String(localized: "身份验证已取消或未通过，工作台仍保持隐藏。")
    }
  }
}
