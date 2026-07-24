import Combine
import Foundation

/// The small slice of root workspace state needed by the split layout.
///
/// Keeping this separate prevents editor, AI, repository, and knowledge child
/// store publications from invalidating the entire workspace hierarchy.
@MainActor
public final class WorkbenchWorkspaceLayoutFeatureFacade: ObservableObject {
  @Published public private(set) var selectedSection: WorkspaceSection
  private var cancellable: AnyCancellable?

  init(store: WorkbenchStore) {
    selectedSection = store.publishingStore.selectedSection
    cancellable = store.publishingStore.$selectedSection
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] section in
        self?.selectedSection = section
      }
  }
}
