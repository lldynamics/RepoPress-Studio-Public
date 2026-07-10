import AppKit
import PublishingWorkbenchCore
import SwiftUI

@main
struct PersonalSitePublisherMacApp: App {
  @NSApplicationDelegateAdaptor(PersonalSitePublisherMacAppDelegate.self) private var appDelegate
  @StateObject private var store: WorkbenchStore
  @StateObject private var storeKitProEntitlementCoordinator = StoreKitProEntitlementCoordinator()

  init() {
    WindowRestorationPolicy.disableAutomaticRestoration()
    let workbenchStore = WorkbenchStore(
      persistence: ScreenshotDemoDataService.preparePersistenceIfEnabled()
    )
    _store = StateObject(
      wrappedValue: workbenchStore
    )
    appDelegate.workbenchStore = workbenchStore
  }

  var body: some Scene {
    Window("个人网站发布控制台", id: "main-workbench") {
      ContentView(store: store)
        .frame(minWidth: 980, minHeight: 720)
        .task {
          storeKitProEntitlementCoordinator.start(store: store)
        }
    }
    .commands {
      PublishingConsoleCommands(store: store)
    }

    WindowGroup("文章编辑", for: UUID.self) { $draftID in
      DraftEditorWindowView(store: store, draftID: draftID)
        .frame(minWidth: 980, minHeight: 680)
    }

    Settings {
      ProtectedSettingsView(
        store: store,
        storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
      )
    }
  }
}

final class PersonalSitePublisherMacAppDelegate: NSObject, NSApplicationDelegate {
  weak var workbenchStore: WorkbenchStore?
  private var windowVisibilityObserver: NSObjectProtocol?

  func applicationWillFinishLaunching(_ notification: Notification) {
    WindowRestorationPolicy.disableAutomaticRestoration()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    WindowRestorationPolicy.disableAutomaticRestoration()
    disableRestorationForVisibleWindows()
    windowVisibilityObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard let window = notification.object as? NSWindow else {
        return
      }
      window.isRestorable = false
    }

    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.async {
      self.disableRestorationForVisibleWindows()
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let workbenchStore, !workbenchStore.flushPendingChanges() else {
      return .terminateNow
    }

    let alert = NSAlert()
    alert.messageText = "未能保存工作台修改"
    alert.informativeText = workbenchStore.lastSaveError ?? "请修复保存位置或权限后重试。应用将保持打开，避免丢失未保存修改。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "继续编辑")
    alert.runModal()
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = workbenchStore?.flushPendingChanges()
  }

  deinit {
    if let windowVisibilityObserver {
      NotificationCenter.default.removeObserver(windowVisibilityObserver)
    }
  }

  private func disableRestorationForVisibleWindows() {
    for window in NSApp.windows {
      window.isRestorable = false
    }
  }
}

private enum WindowRestorationPolicy {
  static func disableAutomaticRestoration() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: "ApplePersistenceIgnoreState")
    defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
  }
}

private struct ProtectedSettingsView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      SettingsView(
        store: store,
        storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
      )
      .disabled(!store.canUseProtectedWorkbench)
      .accessibilityHidden(store.isPrivacyLocked)

      if store.isPrivacyLocked {
        PrivacyLockOverlay(store: store)
      }
    }
    .onChange(of: scenePhase) { _, newValue in
      if newValue != .active {
        store.lockPrivacyIfNeededForInactiveScene()
      }
    }
  }
}
