import AppKit
import PublishingWorkbenchCore
import SwiftUI

@main
struct PersonalSitePublisherMacApp: App {
  @NSApplicationDelegateAdaptor(PersonalSitePublisherMacAppDelegate.self) private var appDelegate
  @StateObject private var store: WorkbenchStore
  @StateObject private var storeKitProEntitlementCoordinator = StoreKitProEntitlementCoordinator()
  @StateObject private var browserBridge: KnowledgeBrowserBridge

  init() {
    // Earlier builds disabled AppKit restoration globally. Remove those sticky
    // overrides now that the main workspace is owned by a native SwiftUI scene.
    UserDefaults.standard.removeObject(forKey: "ApplePersistenceIgnoreState")
    UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
    let knowledgeRestoreOutcome = KnowledgeLibraryService.applyPendingRestoreIfNeeded()
#if DEBUG
    let workbenchStore = WorkbenchStore(
      persistence: ScreenshotDemoDataService.preparePersistenceIfEnabled(),
      freshWorkspaceSeedPolicy: .softwareGuides
    )
#else
    let workbenchStore = WorkbenchStore(freshWorkspaceSeedPolicy: .softwareGuides)
#endif
    workbenchStore.knowledge.reportStartupRestoreOutcome(knowledgeRestoreOutcome)
    _store = StateObject(
      wrappedValue: workbenchStore
    )
    let browserBridge = KnowledgeBrowserBridge(
      knowledge: workbenchStore.knowledge,
      onOpenDocument: { _ in
        workbenchStore.selectSection(.library)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }
    )
    _browserBridge = StateObject(wrappedValue: browserBridge)
    appDelegate.workbenchStore = workbenchStore
    appDelegate.browserBridge = browserBridge
  }

  var body: some Scene {
    WindowGroup("个人网站发布控制台", id: "main-workbench") {
      ContentView(store: store)
        .environmentObject(browserBridge)
        .frame(minWidth: 980, minHeight: 720)
        .tint(WorkbenchTheme.navigationSelection)
        .task {
          storeKitProEntitlementCoordinator.start(store: store)
#if !APP_STORE_BUILD
          browserBridge.start()
#endif
        }
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(replacing: .newItem) {}
      PublishingConsoleCommands(store: store)
    }

    Settings {
      ProtectedSettingsView(
        store: store,
        storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
      )
      .tint(WorkbenchTheme.navigationSelection)
    }
  }
}

@MainActor
final class PersonalSitePublisherMacAppDelegate: NSObject, NSApplicationDelegate {
  var workbenchStore: WorkbenchStore?
  var browserBridge: KnowledgeBrowserBridge?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
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
  }
}
