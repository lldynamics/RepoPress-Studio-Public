import AppKit
import PublishingWorkbenchCore
import SwiftUI
#if DEBUG
import PublishingWorkbenchScreenshotSupport
#endif

@main
struct PersonalSitePublisherMacApp: App {
  @NSApplicationDelegateAdaptor(PersonalSitePublisherMacAppDelegate.self) private var appDelegate
  @StateObject private var store: WorkbenchStore
  @StateObject private var storeKitProEntitlementCoordinator = StoreKitProEntitlementCoordinator()

  init() {
    WindowRestorationPolicy.disableAutomaticRestoration()
#if DEBUG
    let workbenchStore = WorkbenchStore(
      persistence: ScreenshotDemoDataService.preparePersistenceIfEnabled()
    )
#else
    let workbenchStore = WorkbenchStore()
#endif
    _store = StateObject(
      wrappedValue: workbenchStore
    )
    appDelegate.workbenchStore = workbenchStore
  }

  var body: some Scene {
    Window("个人网站发布控制台", id: "main-workbench") {
      ContentView(store: store)
        .frame(minWidth: 980, minHeight: 720)
        .tint(WorkbenchTheme.default.primary)
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
        .tint(WorkbenchTheme.default.primary)
    }

    Settings {
      ProtectedSettingsView(
        store: store,
        storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
      )
      .tint(WorkbenchTheme.default.primary)
    }
  }
}

@MainActor
final class PersonalSitePublisherMacAppDelegate: NSObject, NSApplicationDelegate {
  weak var workbenchStore: WorkbenchStore?

  func applicationWillFinishLaunching(_ notification: Notification) {
    WindowRestorationPolicy.disableAutomaticRestoration()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    WindowRestorationPolicy.disableAutomaticRestoration()
    disableRestorationForVisibleWindows()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )

    NSApp.setActivationPolicy(.regular)
    Task { @MainActor [weak self] in
      self?.disableRestorationForVisibleWindows()
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
    workbenchStore?.stopLocalSitePreviewImmediately()
    _ = workbenchStore?.flushPendingChanges()
  }

  @objc private func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    window.isRestorable = false
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
