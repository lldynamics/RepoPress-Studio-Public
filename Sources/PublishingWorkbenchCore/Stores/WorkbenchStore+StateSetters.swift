import Foundation

extension WorkbenchStore {
  public func updateActiveProfile(_ profile: SiteProfile) {
    publishingStore.activeProfile = profile
    invalidateDraftDerivedCaches()
  }

  func setProfiles(_ profiles: [SiteProfile]) {
    publishingStore.profiles = profiles
    invalidateDraftDerivedCaches()
  }

  func setDrafts(_ drafts: [ArticleDraft]) {
    publishingStore.drafts = drafts
    invalidateDraftDerivedCaches()
  }

  func setRepositoryReport(_ report: RepositoryScanReport?) {
    repositoryStore.repositoryReport = report
    invalidateDraftDerivedCaches()
  }

  func setImageWorkbenchReport(_ report: ImageWorkbenchReport?) {
    publishingStore.imageWorkbenchReport = report
    invalidateDraftTaskQueueStateCache()
  }

  func setSelectedDraftID(_ draftID: UUID?) {
    publishingStore.selectedDraftID = draftID
  }

  func setSelectedSection(_ section: WorkspaceSection) {
    publishingStore.selectedSection = section
  }

  func setPreflightIssues(_ issues: [PreflightIssue]) {
    publishingStore.preflightIssues = issues
  }

}
