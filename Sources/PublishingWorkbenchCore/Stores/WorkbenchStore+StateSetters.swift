import Foundation

extension WorkbenchStore {
  public func updateActiveProfile(_ profile: SiteProfile) {
    let synchronizedProfile = synchronizeSelectedAIConnectionIfNeeded(with: profile)
    publishingStore.activeProfile = synchronizedProfile
    invalidateDraftDerivedCaches()
  }

  /// Keeps callers that still edit the legacy site-owned AI config compatible
  /// with reusable connection profiles. A shared connection remains the source
  /// of truth, so an inline edit updates every site currently selecting it.
  private func synchronizeSelectedAIConnectionIfNeeded(with profile: SiteProfile) -> SiteProfile {
    guard
      let existingProfile = publishingStore.profiles.first(where: { $0.id == profile.id }),
      existingProfile.aiConnectionProfileID == profile.aiConnectionProfileID,
      existingProfile.aiProviderConfig != profile.aiProviderConfig,
      let connectionID = profile.aiConnectionProfileID,
      let connectionIndex = aiConnectionProfiles.firstIndex(where: { $0.id == connectionID })
    else {
      return profile
    }

    guard
      invalidateAIConnectionProfileCredentialsIfNeeded(
        from: aiConnectionProfiles[connectionIndex].config,
        to: profile.aiProviderConfig,
        connectionProfileID: connectionID
      )
    else {
      var rejectedProfile = profile
      rejectedProfile.aiProviderConfig = existingProfile.aiProviderConfig
      return rejectedProfile
    }
    aiConnectionProfiles[connectionIndex].config = profile.aiProviderConfig
    for siteIndex in publishingStore.profiles.indices
    where publishingStore.profiles[siteIndex].aiConnectionProfileID == connectionID {
      publishingStore.profiles[siteIndex].aiProviderConfig = profile.aiProviderConfig
    }
    return profile
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
    repositoryStore.replaceRepositoryReport(report, profileID: activeProfileID)
    invalidateDraftDerivedCaches()
  }

  func setImageWorkbenchReport(_ report: ImageWorkbenchReport?) {
    publishingStore.imageWorkbenchReport = report
    // Per-draft reports drive the selected image inspector directly. Draft
    // queue image counts come from the site-wide summary, whose refresh path
    // owns the corresponding cache invalidation.
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
