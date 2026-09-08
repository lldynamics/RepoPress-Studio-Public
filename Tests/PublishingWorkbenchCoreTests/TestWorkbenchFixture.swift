import Foundation

@testable import PublishingWorkbenchCore

/// Builds a fresh workbench without touching application support, Keychain, or
/// the process-wide AI consent preferences.
@MainActor
final class TestWorkbenchFixture {
  let store: WorkbenchStore

  private let persistenceURL: URL
  private let defaults: UserDefaults
  private let suiteName: String

  init() {
    suiteName = "PublishingWorkbenchCoreTests.WorkbenchFixture.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchFixture-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")

    let consentStore = AIDataSharingConsentStore(defaults: defaults)
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.WorkbenchFixture.\(UUID().uuidString)",
      accountPrefix: "workbench-fixture",
      inMemory: true
    )
    let configuredStore = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)),
      freshWorkspaceSeedPolicy: .blank,
      keychainTokenStore: tokenStore,
      aiDataSharingConsentStore: consentStore
    )
    // The blank preloaded snapshot intentionally has no selected document;
    // create one explicitly for tests that exercise article-scoped behavior.
    configuredStore.createDraft()
    store = configuredStore
  }

  deinit {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent())
  }
}
