import Foundation

extension WorkbenchStore {
  public func stopLocalSitePreview() {
    publishingStore.stopLocalSitePreview()
  }

  public func stopLocalSitePreviewImmediately() {
    publishingStore.stopLocalSitePreviewImmediately()
  }

  public func startLocalSitePreview() {
    publishingStore.refreshLocalSitePreviewPlan(
      for: activeProfile,
      repositoryReport: repositoryReport(for: activeProfile)
    )
    publishingStore.startLocalSitePreview()
  }

  public func refreshLocalSitePreviewRuntimeStatus() {
    publishingStore.refreshLocalSitePreviewRuntimeStatus()
  }

  public func verifyLocalSitePreviewReachability() async {
    await publishingStore.verifyLocalSitePreviewReachability()
  }

  public func updateActiveProfile(_ update: (inout SiteProfile) -> Void) {
    publishingStore.updateActiveProfile(update, store: self)
    invalidateDraftDerivedCaches()
  }

  public func applySiteKindDefaults(_ siteKind: SiteKind) {
    publishingStore.applySiteKindDefaults(siteKind, store: self)
    invalidateDraftDerivedCaches()
  }

  @discardableResult
  public func createSiteFromStarter(_ request: SiteStarterRequest) async -> SiteStarterResult? {
    await waitForPendingDraftWordCountRefreshes()
    return await publishingStore.createSiteFromStarter(request, store: self)
  }

  @discardableResult
  public func importExistingSiteFromStarter(_ request: SiteStarterImportRequest) async -> SiteStarterImportResult? {
    await waitForPendingDraftWordCountRefreshes()
    return await publishingStore.importExistingSiteFromStarter(request, store: self)
  }

  @discardableResult
  public func configureStarterSiteOrigin() async -> Bool {
    await publishingStore.configureStarterSiteOrigin(store: self)
  }

  @discardableResult
  public func commitAndPushStarterSite() async -> SiteStarterPushResult? {
    await publishingStore.commitAndPushStarterSite(store: self)
  }

  @discardableResult
  public func createGitHubRepositoryForActiveProfile(
    privateRepository: Bool = true
  ) async -> RemoteRepositoryCreationResult? {
    await publishingStore.createGitHubRepositoryForActiveProfile(privateRepository: privateRepository, store: self)
  }

  public func selectProfile(_ id: UUID) {
    publishingStore.selectProfile(id, store: self)
    repositoryDeploymentCoordinator.refreshTokenAvailability(store: self)
    invalidateDraftDerivedCaches()
  }

  public func selectSection(_ section: WorkspaceSection) {
    aiStore.hideAIPublishingAssistant()
    publishingStore.selectSection(section)
  }

  public func createProfile(named name: String? = nil) -> SiteProfile {
    publishingStore.createProfile(named: name, store: self)
  }

  /// Switches the first-run workspace to a repository-free general-draft mode.
  ///
  /// A brand-new workbench reuses its empty default profile so the user does
  /// not get an extra, unconfigured site profile. If the app already contains
  /// a configured site or site drafts, keep that profile intact and create a
  /// separate general-draft profile instead.
  public func prepareLocalDraftWorkspace() {
    let untouchedInitialDraftID = drafts.first { draft in
      draft.belongs(toSiteProfileID: activeProfileID)
        && isUntouchedInitialSiteDraft(draft)
    }?.id
    let hasActiveProfileContent = drafts.contains { draft in
      draft.belongs(toSiteProfileID: activeProfileID)
        && !isUntouchedInitialSiteDraft(draft)
    }
    let canReuseActiveProfile = activeProfile.purpose == .generalDraftBackup
      || (
        profiles.count == 1
          && activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
          && !hasActiveProfileContent
      )

    if !canReuseActiveProfile {
      _ = createProfile(named: "本地草稿")
    }

    updateActiveProfile { profile in
      profile.name = "本地草稿"
      profile.purpose = .generalDraftBackup
      profile.localRepositoryRootPath = ""
      profile.repoOwner = ""
      profile.repoName = ""
      profile.deploymentProvider = nil
      profile.deploymentSiteURL = nil
      profile.deploymentStatusEndpointURL = nil
      profile.deploymentStatusEndpointUsesToken = nil
      profile.deploymentProjectID = nil
      profile.deploymentAccountID = nil
    }

    if canReuseActiveProfile,
       let untouchedInitialDraftID,
       var draft = drafts.first(where: { $0.id == untouchedInitialDraftID }) {
      draft.assignToGeneralDraft(editingProfileID: activeProfileID)
      updateDraft(draft)
    }

    setDraftListContentScope(.general)
    if let draft = writingDrafts.first {
      _ = focusDraft(draft.id, section: .writing)
    } else {
      createGeneralDraft()
    }
  }

  private func isUntouchedInitialSiteDraft(_ draft: ArticleDraft) -> Bool {
    !draft.isGeneralDraft
      && draft.title == "未命名文章"
      && draft.bodyMarkdown == "# 未命名文章\n\n从这里开始写作。\n"
      && draft.summary.isEmpty
      && draft.attachments.isEmpty
  }

  public func duplicateActiveProfile() -> SiteProfile {
    publishingStore.duplicateActiveProfile(store: self)
  }

  public var activeProfileDraftCount: Int {
    publishingStore.activeProfileDraftCount()
  }

  public var recentlyDeletedProfile: RecentlyDeletedProfile? {
    publishingStore.recentlyDeletedProfile
  }

  @discardableResult
  public func deleteActiveProfile() -> RecentlyDeletedProfile? {
    publishingStore.deleteActiveProfile(store: self)
  }

  @discardableResult
  public func restoreRecentlyDeletedProfile() -> Bool {
    publishingStore.restoreRecentlyDeletedProfile(store: self)
  }
}
