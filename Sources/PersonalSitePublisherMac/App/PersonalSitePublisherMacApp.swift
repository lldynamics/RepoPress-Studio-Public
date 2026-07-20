import AppKit
import PublishingWorkbenchCore
import SwiftUI

@main
struct PersonalSitePublisherMacApp: App {
  @NSApplicationDelegateAdaptor(PersonalSitePublisherMacAppDelegate.self) private var appDelegate
  @StateObject private var launchCoordinator: WorkbenchLaunchCoordinator
  @StateObject private var storeKitProEntitlementCoordinator = StoreKitProEntitlementCoordinator()

  init() {
    // Earlier builds disabled AppKit restoration globally. Remove those sticky
    // overrides now that the main workspace is owned by a native SwiftUI scene.
#if DEBUG
    // Deterministic screenshot and XCUI launches pass temporary restoration
    // overrides on the command line. Keep those volatile values for the
    // automated run so AppKit cannot reopen a stale workspace window while the
    // requested demo surface is being installed.
    if ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"] != "1" {
      UserDefaults.standard.removeObject(forKey: "ApplePersistenceIgnoreState")
      UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
    }
#else
    UserDefaults.standard.removeObject(forKey: "ApplePersistenceIgnoreState")
    UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
#endif
#if DEBUG
    let knowledgeLibraryService = ScreenshotDemoDataService.prepareKnowledgeLibraryServiceIfEnabled()
#else
    let knowledgeLibraryService = KnowledgeLibraryService()
#endif
#if DEBUG
    let persistence = ScreenshotDemoDataService.preparePersistenceIfEnabled()
#else
    let persistence = WorkbenchPersistence()
#endif
    _launchCoordinator = StateObject(
      wrappedValue: WorkbenchLaunchCoordinator(
        persistence: persistence,
        knowledgeLibraryService: knowledgeLibraryService
      )
    )
  }

  var body: some Scene {
    WindowGroup("个人网站发布控制台", id: "main-workbench") {
      WorkbenchLaunchRootView(
        coordinator: launchCoordinator,
        storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator,
        onReady: { store, browserBridge in
          appDelegate.workbenchStore = store
          appDelegate.browserBridge = browserBridge
        }
      )
        .frame(
          minWidth: WorkbenchLayoutMode.minimumWindowWidth,
          minHeight: 720
        )
        .background(MainWindowInitialSizeBridge())
#if DEBUG
        .background(ScreenshotCaptureWindowBridge())
#endif
        .tint(WorkbenchTheme.navigationSelection)
    }
    .defaultSize(
      width: WorkbenchLayoutMode.defaultWindowWidth,
      height: WorkbenchLayoutMode.defaultWindowHeight
    )
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(replacing: .newItem) {}
      if let store = launchCoordinator.store {
        PublishingConsoleCommands(store: store)
      }
    }

    Settings {
      Group {
        if let store = launchCoordinator.store {
          ProtectedSettingsView(
            store: store,
            storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
          )
        } else {
          ProgressView()
            .frame(width: 420, height: 300)
        }
      }
        .tint(WorkbenchTheme.navigationSelection)
    }
  }
}

@MainActor
final class PersonalSitePublisherMacAppDelegate: NSObject, NSApplicationDelegate {
  private let privacyIdleLockController = PrivacyIdleLockController()
  var workbenchStore: WorkbenchStore? {
    didSet {
      guard oldValue !== workbenchStore else { return }
      if let workbenchStore {
        privacyIdleLockController.start(monitoring: workbenchStore)
      } else {
        privacyIdleLockController.stop()
      }
    }
  }
  var browserBridge: KnowledgeBrowserBridge?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
#if !APP_STORE_BUILD
    Task.detached(priority: .utility) {
      _ = BrowserNativeMessagingInstaller.repairInstalledConnectionsAfterUpgrade()
    }
#endif
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let workbenchStore, !workbenchStore.flushPendingChanges() else {
      return .terminateNow
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "未能保存工作台修改")
    alert.informativeText = workbenchStore.lastSaveError
      ?? String(localized: "请修复保存位置或权限后重试。应用将保持打开，避免丢失未保存修改。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "继续编辑"))
    alert.runModal()
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    privacyIdleLockController.stop()
    browserBridge?.stop()
    workbenchStore?.stopLocalSitePreviewImmediately()
    _ = workbenchStore?.flushPendingChanges()
  }

}

private struct ProtectedSettingsView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator

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
#if DEBUG
    .background(ScreenshotCaptureWindowBridge(role: .settings))
#endif
  }
}
