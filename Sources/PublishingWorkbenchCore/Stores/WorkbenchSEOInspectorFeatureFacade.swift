import Combine
import Foundation

/// Narrow observation boundary for the SEO inspector. Editor typing still
/// reaches the view through its draft binding, while unrelated AI streaming,
/// publishing progress, repository scans and image work do not invalidate it.
@MainActor
public final class WorkbenchSEOInspectorFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store
    observe(store.aiWorkspaceStore.$seoSocialPreviewSnapshots)
    observe(store.aiWorkspaceStore.$seoSocialPreviewMessage)
    observe(store.siteMaintenanceStore.$snapshotVersion)
    observe(store.publishingStore.$profiles)
  }

  public func socialPreviewSnapshot(for draft: ArticleDraft) -> SEOSocialPreviewSnapshot? {
    store.seoSocialPreviewSnapshot(for: draft)
  }

  public var maintenanceSnapshotDate: Date? {
    store.siteMaintenanceSnapshot?.generatedAt
  }

  public var actionMessage: String? {
    store.seoSocialPreviewMessage
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
