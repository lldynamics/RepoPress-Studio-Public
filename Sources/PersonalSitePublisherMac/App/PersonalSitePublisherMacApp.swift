import AppKit
import PublishingWorkbenchCore
import SwiftUI

@main
struct PersonalSitePublisherMacApp: App {
  @NSApplicationDelegateAdaptor(PersonalSitePublisherMacAppDelegate.self) private var appDelegate
  @StateObject private var launchCoordinator: WorkbenchLaunchCoordinator
  @StateObject private var appUpdateController = AppUpdateController()
  @AppStorage(WorkbenchAccentPalette.storageKey)
  private var accentPaletteRawValue = WorkbenchAccentPalette.system.rawValue

  init() {
    NSScrollView.enableGlobalThinRedScrollers()
    AppLanguagePreference.prepareForLaunch()
    // Earlier builds disabled AppKit restoration globally. Remove those sticky
    // overrides now that the main workspace is owned by a native SwiftUI scene.
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
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
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    if ScreenshotDemoDataService.isEnabledFromEnvironment {
      let persistence = ScreenshotDemoDataService.preparePersistenceIfEnabled()
      let demoRootURL = persistence.fileURL.deletingLastPathComponent()
      let knowledgeLibraryService = KnowledgeLibraryService(
        rootURL: demoRootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
      )
      _launchCoordinator = StateObject(
        wrappedValue: WorkbenchLaunchCoordinator(
          persistence: persistence,
          knowledgeLibraryService: knowledgeLibraryService,
          rssReaderFileURL: demoRootURL
            .appendingPathComponent("RSSReader", isDirectory: true)
            .appendingPathComponent("reader.sqlite", isDirectory: false),
          managedAttachmentFileStore: ManagedAttachmentFileStore(
            rootDirectoryURL: demoRootURL.appendingPathComponent(
              "ManagedAttachments",
              isDirectory: true
            )
          ),
          workspaceBackupDirectoryURL: demoRootURL.appendingPathComponent(
            WorkspaceBackupService.automaticBackupDirectoryName,
            isDirectory: true
          )
        )
      )
    } else {
      _launchCoordinator = StateObject(wrappedValue: WorkbenchLaunchCoordinator())
    }
#else
    _launchCoordinator = StateObject(wrappedValue: WorkbenchLaunchCoordinator())
#endif
  }

  var body: some Scene {
    WindowGroup("RepoPress Studio", id: "main-workbench") {
      WorkbenchLaunchRootView(
        coordinator: launchCoordinator,
        onReady: { store, browserBridge in
          appDelegate.workbenchStore = store
          appDelegate.browserBridge = browserBridge
        }
      )
        .frame(
          minWidth: WorkbenchLayoutMode.minimumWindowWidth,
          minHeight: WorkbenchLayoutMode.minimumWindowHeight
        )
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
        .background(ScreenshotCaptureWindowBridge())
#endif
        .background(
          MainWindowOpenActionRegistration { action in
            appDelegate.openMainWindowAction = action
          }
        )
        .tint(selectedAccentPalette.color)
    }
    .defaultSize(
      width: WorkbenchLayoutMode.defaultWindowWidth,
      height: WorkbenchLayoutMode.defaultWindowHeight
    )
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      AppUpdateCommands(controller: appUpdateController)
      if let store = launchCoordinator.store {
        PublishingConsoleCommands(store: store)
      }
    }

    Settings {
      Group {
        if let store = launchCoordinator.store {
          ProtectedSettingsView(
            store: store,
            rssStore: launchCoordinator.rssStore,
            launchCoordinator: launchCoordinator
          )
        } else {
          VStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.plus")
              .font(.title)
              .foregroundStyle(.secondary)
            Text("请先在主窗口完成数据文件夹设置。")
              .foregroundStyle(.secondary)
          }
          .workbenchSettingsWindowSize()
        }
      }
        .tint(selectedAccentPalette.color)
    }
  }

  private var selectedAccentPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }
}

private struct MainWindowOpenActionRegistration: View {
  @Environment(\.openWindow) private var openWindow
  let register: (@escaping () -> Void) -> Void

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        register {
          openWindow(id: "main-workbench")
        }
      }
  }
}

@MainActor
final class PersonalSitePublisherMacAppDelegate: NSObject, NSApplicationDelegate {
  var workbenchStore: WorkbenchStore?
  var browserBridge: KnowledgeBrowserBridge?
  var openMainWindowAction: (() -> Void)?

  private let reopenMenuItemIdentifier = NSUserInterfaceItemIdentifier(
    "com.jinfang.repopress-studio.show-main-window"
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mainWindowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: nil
    )
    installPersistentWindowCommands()
    normalizeVisibleApplicationName()
    scheduleMainWindowRecoveryIfNeeded()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    installPersistentWindowCommands()
    normalizeVisibleApplicationName()
    scheduleMainWindowRecoveryIfNeeded()
  }

  func applicationDidUpdate(_ notification: Notification) {
    installPersistentWindowCommands()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else { return true }
    if restoreMainWindow(in: sender) {
      return false
    }
    return true
  }

  @objc
  private func showMainWindow(_ sender: Any?) {
    NSApp.activate(ignoringOtherApps: true)
    _ = restoreMainWindow(in: NSApp)
  }

  @objc
  private func mainWindowWillClose(_ notification: Notification) {
    // SwiftUI removes scene-scoped command contributions after the last
    // WindowGroup window closes. Reinstall this AppKit-owned command after
    // that scene teardown so the Window menu remains actionable.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.installPersistentWindowCommands()
      self?.normalizeVisibleApplicationName()
    }
  }

  private func restoreMainWindow(in application: NSApplication) -> Bool {
    if let mainWindow = application.windows.first(where: isMainWorkbenchWindow) {
      if mainWindow.isMiniaturized {
        mainWindow.deminiaturize(nil)
      }
      mainWindow.makeKeyAndOrderFront(nil)
      return true
    }
    guard let openMainWindowAction else { return false }
    openMainWindowAction()
    return true
  }

  private func scheduleMainWindowRecoveryIfNeeded() {
    // AppKit finishes restoring SwiftUI scene windows after the application
    // delegate launch callbacks. A previously closed or hidden restoration
    // record can therefore leave a healthy process with no visible UI. Wait
    // for that restoration pass, then surface the existing workbench window
    // (or ask the WindowGroup to create one once its open action is ready).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self,
            !NSApp.windows.contains(where: \.isVisible)
      else {
        return
      }
      _ = self.restoreMainWindow(in: NSApp)
    }
  }

  private func isMainWorkbenchWindow(_ window: NSWindow) -> Bool {
    if let identifier = window.identifier?.rawValue,
       identifier.contains("main-workbench") {
      return true
    }
    return window.title == "RepoPress Studio" || window.title == "RepoPress"
  }

  private func installPersistentWindowCommands() {
    guard let windowMenu = resolveWindowMenu() else { return }
    if windowMenu.items.contains(where: { $0.identifier == reopenMenuItemIdentifier }) {
      return
    }

    let reopenItem = NSMenuItem(
      title: String(localized: "显示 RepoPress Studio"),
      action: #selector(showMainWindow(_:)),
      keyEquivalent: "0"
    )
    reopenItem.identifier = reopenMenuItemIdentifier
    reopenItem.keyEquivalentModifierMask = [.command]
    reopenItem.target = self
    windowMenu.insertItem(reopenItem, at: 0)
    windowMenu.insertItem(.separator(), at: 1)
  }

  private func resolveWindowMenu() -> NSMenu? {
    if let windowsMenu = NSApp.windowsMenu {
      return windowsMenu
    }
    return NSApp.mainMenu?.items.compactMap(\.submenu).first { menu in
      menu.items.contains {
        $0.action == #selector(NSWindow.performMiniaturize(_:))
      } && menu.items.contains {
        $0.action == #selector(NSWindow.performZoom(_:))
      }
    }
  }

  private func normalizeVisibleApplicationName() {
    guard let applicationMenuItem = NSApp.mainMenu?.items.first else { return }
    applicationMenuItem.title = "RepoPress Studio"
    applicationMenuItem.submenu?.title = "RepoPress Studio"
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if RepositoryHTMLSourceSessionRegistry.shared.hasUnsavedChanges {
      let alert = NSAlert()
      alert.messageText = String(localized: "HTML 源文件尚未保存")
      alert.informativeText = String(localized: "保存后退出可保留源码更改；也可以返回编辑器继续处理。")
      alert.alertStyle = .warning
      alert.addButton(withTitle: String(localized: "保存并退出"))
      alert.addButton(withTitle: String(localized: "继续编辑")).keyEquivalent = "\u{1b}"
      alert.addButton(withTitle: String(localized: "不保存并退出"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        guard RepositoryHTMLSourceSessionRegistry.shared.saveBeforeTermination() else {
          let failureAlert = NSAlert()
          failureAlert.messageText = String(localized: "未能保存 HTML 源文件")
          failureAlert.informativeText = RepositoryHTMLSourceSessionRegistry.shared.lastErrorMessage
            ?? String(localized: "请返回编辑器检查文件权限或外部修改冲突。")
          failureAlert.alertStyle = .warning
          failureAlert.addButton(withTitle: String(localized: "继续编辑"))
          failureAlert.runModal()
          return .terminateCancel
        }
      case .alertSecondButtonReturn:
        return .terminateCancel
      case .alertThirdButtonReturn:
        break
      default:
        return .terminateCancel
      }
    }

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
    let didFlush = workbenchStore?.flushPendingChanges() ?? true
    if didFlush {
      WorkbenchSessionRecovery.shared.markCleanExit()
    }
  }

}

private struct ProtectedSettingsView: View {
  @ObservedObject var store: WorkbenchStore
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator

  var body: some View {
    ZStack {
      SettingsView(
        store: store,
        rssStore: rssStore,
        launchCoordinator: launchCoordinator
      )
      .disabled(!store.canUseProtectedWorkbench)
      .disabled(launchCoordinator.phase != .ready)
      .accessibilityHidden(store.isQuickHideActive)

      if store.isQuickHideActive {
        QuickHideOverlay(store: store)
      }
    }
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    .background(ScreenshotCaptureWindowBridge(role: .settings))
#endif
  }
}
