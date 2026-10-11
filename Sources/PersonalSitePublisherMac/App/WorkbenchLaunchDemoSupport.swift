import PublishingKnowledgeCore
import PublishingWorkbenchCore

/// Keeps fixture setup and its in-memory credentials together. Production
/// builds retain the normal credential services and never enable demo storage.
@MainActor
enum WorkbenchLaunchDemoSupport {
  static func credentialStores() -> (
    ai: KeychainTokenStore, repository: KeychainTokenStore, deployment: KeychainTokenStore
  ) {
    let inMemory: Bool
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      inMemory = ScreenshotDemoDataService.isEnabledFromEnvironment
    #else
      inMemory = false
    #endif
    return (
      KeychainTokenStore(
        service: KeychainCredentialServices.ai, accountPrefix: "ai-provider", inMemory: inMemory),
      KeychainTokenStore(
        service: KeychainCredentialServices.repository, accountPrefix: "repository-provider",
        inMemory: inMemory),
      KeychainTokenStore(
        service: KeychainCredentialServices.deployment, accountPrefix: "deployment-provider",
        inMemory: inMemory)
    )
  }

  static func prepareRSSReaderFixture(in store: RSSReaderStore) {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      ScreenshotDemoDataService.prepareRSSReaderFixtureIfEnabled(in: store)
    #endif
  }

  static func applyRequestedSurface(to store: WorkbenchStore) {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      if ScreenshotDemoDataService.isEnabledFromEnvironment {
        ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
      }
    #endif
  }
}
