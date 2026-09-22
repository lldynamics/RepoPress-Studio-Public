import Combine
import Foundation

/// The list's document-navigation inputs.  It purposely excludes the broader
/// workbench so a sidebar cannot retain or observe unrelated editor services.
@MainActor
public protocol DraftListNavigationReadModel: AnyObject {
  var selectedDraftID: UUID? { get }
  var activeProfileID: UUID { get }
  var contentScope: DraftListContentScope { get }
  var profiles: [SiteProfile] { get }
  var visibleDrafts: [ArticleDraft] { get }
  func profile(for draft: ArticleDraft) -> SiteProfile

  var profilesDidChange: AnyPublisher<[SiteProfile], Never> { get }
  var activeProfileIDDidChange: AnyPublisher<UUID, Never> { get }
  var contentScopeDidChange: AnyPublisher<DraftListContentScope, Never> { get }
}

/// Inputs owned by repository, privacy and image-workbench features that are
/// visible in the Writing sidebar.  They are injected as a small read model.
@MainActor
public protocol DraftListAuxiliaryReadModel: AnyObject {
  var repositoryReport: RepositoryScanReport? { get }
  var masksPrivateContent: Bool { get }
  var imageInputRevision: UInt64 { get }

  var repositoryReportDidChange: AnyPublisher<RepositoryScanReport?, Never> { get }
  var masksPrivateContentDidChange: AnyPublisher<Bool, Never> { get }
}

/// Publishing-owned navigation adapter used while window navigation remains in
/// `PublishingStore`.  It gives document views only the values they need.
@MainActor
public final class PublishingDraftListNavigationReadModel: DraftListNavigationReadModel {
  private unowned let publishing: PublishingStore

  public init(publishing: PublishingStore) {
    self.publishing = publishing
  }

  public var selectedDraftID: UUID? { publishing.selectedDraftID }
  public var activeProfileID: UUID { publishing.activeProfileID }
  public var contentScope: DraftListContentScope { publishing.draftListContentScope }
  public var profiles: [SiteProfile] { publishing.profiles }
  public var visibleDrafts: [ArticleDraft] { publishing.visibleDrafts }
  public func profile(for draft: ArticleDraft) -> SiteProfile { publishing.profile(for: draft) }

  public var profilesDidChange: AnyPublisher<[SiteProfile], Never> {
    publishing.$profiles.eraseToAnyPublisher()
  }

  public var activeProfileIDDidChange: AnyPublisher<UUID, Never> {
    publishing.$activeProfileID.eraseToAnyPublisher()
  }

  public var contentScopeDidChange: AnyPublisher<DraftListContentScope, Never> {
    publishing.$draftListContentScope.eraseToAnyPublisher()
  }
}

/// Compatibility adapter for the current root composition.  The adapter, not
/// `DraftListStore`, owns the narrow bridge to `WorkbenchStore`; root wiring
/// can replace it without changing the list implementation.
@MainActor
public final class WorkbenchDraftListAuxiliaryReadModel: DraftListAuxiliaryReadModel {
  private unowned let workbench: WorkbenchStore

  public init(workbench: WorkbenchStore) {
    self.workbench = workbench
  }

  public var repositoryReport: RepositoryScanReport? { workbench.repositoryReport }
  public var masksPrivateContent: Bool {
    workbench.privacyProtectionStore.privacySettings.masksPrivateContent
  }
  public var imageInputRevision: UInt64 { workbench.imageWorkbenchInputRevision }

  public var repositoryReportDidChange: AnyPublisher<RepositoryScanReport?, Never> {
    workbench.repositoryStore.$repositoryReport.eraseToAnyPublisher()
  }

  public var masksPrivateContentDidChange: AnyPublisher<Bool, Never> {
    workbench.privacyProtectionStore.$privacySettings
      .map(\.masksPrivateContent)
      .eraseToAnyPublisher()
  }
}
