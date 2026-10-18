import AppKit

extension PersonalSitePublisherMacAppDelegate {
  func configureWorkbenchServices(_ cacheMonitor: WorkbenchCacheMemoryPressureMonitor) {
    cacheMonitor.bindKnowledgeStore(workbenchStore?.knowledge)
    guard let workbenchStore else { return }
    ArticlePublishReminderCoordinator.shared.install(store: workbenchStore)
  }

  func configureWorkbenchLaunchActions() {
    ArticlePublishReminderCoordinator.shared.configureLaunch { [weak self] in
      self?.openWorkbenchWindow()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let request = WorkbenchShortcutRequest(url: url) else { continue }
      WorkbenchShortcutCoordinator.shared.enqueue(request)
      openWorkbenchWindow()
    }
  }
}
