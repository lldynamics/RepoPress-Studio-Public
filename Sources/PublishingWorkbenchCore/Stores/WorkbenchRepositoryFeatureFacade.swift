import Foundation

@MainActor
public final class WorkbenchRepositoryFeatureFacade {
  private unowned let store: WorkbenchStore

  init(store: WorkbenchStore) {
    self.store = store
  }

  public var report: RepositoryScanReport? {
    store.repositoryReport
  }

  public var scanState: RepositoryScanState {
    store.repositoryScanState
  }

  public var tokenAvailability: KeychainTokenAvailability {
    store.repositoryTokenAvailability
  }

  public var accessCheck: RemoteRepositoryAccessCheck? {
    store.remoteRepositoryAccessCheck
  }

  public var isChecking: Bool {
    store.isRemoteRepositoryChecking
  }

  public var isPublishing: Bool {
    store.isRemoteRepositoryPublishing
  }

  public func scanAsync() async {
    await store.scanRepositoryAsync()
  }

  public func cancelScan() {
    store.cancelRepositoryScan()
  }

  public func rememberRootAsync(_ url: URL) async {
    await store.rememberRepositoryRootAsync(url)
  }

  public func report(for profile: SiteProfile) -> RepositoryScanReport? {
    store.repositoryReport(for: profile)
  }
}
