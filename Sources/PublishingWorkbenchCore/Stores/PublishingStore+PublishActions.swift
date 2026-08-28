import Foundation
extension PublishingStore {
  public internal(set) var activeProfile: SiteProfile {
    get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
    set {
      if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
        profiles[index] = newValue
      } else {
        profiles.insert(newValue, at: 0)
      }
      activeProfileID = newValue.id
    }
  }

  public var selectedDraft: ArticleDraft? {
    DraftListProjection.selectedDraft(
      drafts,
      selectedDraftID: selectedDraftID,
      activeProfileID: activeProfileID,
      scope: draftListContentScope
    )
  }

  /// Site-owned drafts for repository, publishing, maintenance and batch operations.
  public var visibleDrafts: [ArticleDraft] {
    DraftListProjection.siteDrafts(drafts, for: activeProfileID)
  }

  /// Drafts shown by the Writing sidebar for its currently selected content scope.
  public var writingDrafts: [ArticleDraft] {
    DraftListProjection.writingDrafts(
      drafts,
      activeProfileID: activeProfileID,
      scope: draftListContentScope
    )
  }

  var generalDraftPublishingIssue: PreflightIssue {
    PreflightIssue(
      severity: .error,
      title: CoreL10n.text("通用草稿不能直接发布"),
      message: CoreL10n.text("请先将它复制到目标站点，再执行写入、提交或线上发布。"),
      field: "scope"
    )
  }

  @discardableResult
  func blockPublishingIfGeneralDraftSelected(store: WorkbenchStore) -> Bool {
    guard store.selectedDraft?.isGeneralDraft == true else { return false }
    setPublishActionMessage(generalDraftPublishingIssue.message, status: .warning)
    return true
  }

  /// Returns a package that is guaranteed to belong to the article selected at
  /// execution time. Shared preview state may still contain the previous
  /// article while an asynchronous refresh is running, so publishing commands
  /// must never trust it without this check.
  func publishPackageForSelectedDraft(store: WorkbenchStore) -> PublishPackage? {
    guard let selectedDraft = store.selectedDraft, !selectedDraft.isGeneralDraft else {
      return nil
    }
    store.flushDraftBodyEditorBuffer(for: selectedDraft.id)
    let currentDraft = store.draft(for: selectedDraft.id) ?? selectedDraft
    let currentBaseline = makeDraftPublishPreviewInputBaseline(
      for: currentDraft,
      store: store
    )
    let cachedSnapshot = draftPublishPreviewSnapshot(for: selectedDraft.id)
    let cacheIsCurrent =
      cachedSnapshot?.context == currentBaseline.context
      && cachedSnapshot?.publishPackage.draftID == selectedDraft.id
      && rememberedDraftPublishPreviewInputBaseline(for: selectedDraft.id)
        == currentBaseline
    if !cacheIsCurrent {
      refreshPublishPreview(for: currentDraft, store: store)
    }
    guard let snapshot = draftPublishPreviewSnapshot(for: selectedDraft.id),
      snapshot.context == currentBaseline.context,
      rememberedDraftPublishPreviewInputBaseline(for: selectedDraft.id)
        == currentBaseline,
      snapshot.publishPackage.draftID == selectedDraft.id
    else {
      return nil
    }
    return snapshot.publishPackage
  }

  /// Records the exact Markdown payload that was written by a local publish
  /// operation.  Local writes are also repository materialization: once the
  /// file exists, subsequent editor changes may safely use the normal draft
  /// autosave path.
  @discardableResult
  func recordLocalRepositoryWriteBinding(
    package: PublishPackage,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> Bool {
    guard
      let markdownFile = package.files.first(where: {
        $0.kind == .markdown && $0.operation == .upsert
      }),
      let content = markdownFile.content,
      let index = drafts.firstIndex(where: { $0.id == package.draftID })
    else {
      return false
    }

    let renderedContentDigest = ArticleDraft.repositoryDocumentDigest(content)
    let previousDraft = drafts[index]
    var updatedDraft = previousDraft
    guard updatedDraft.belongs(toSiteProfileID: profile.id) else { return false }
    updatedDraft.recordProjectFile(
      profile: profile,
      repositoryPath: markdownFile.repositoryPath,
      renderedContentDigest: renderedContentDigest
    )
    if updatedDraft != previousDraft {
      updatedDraft.markUpdated(at: previousDraft.updatedAt, replacing: previousDraft)
      drafts[index] = updatedDraft
    }
    removeDraftPublishPreviewSnapshot(for: updatedDraft.id)
    if updatedDraft.renderedRepositoryContentDigest(profile: profile) == renderedContentDigest {
      store.siteDraftFileSaveStates[updatedDraft.id] = .saved(
        repositoryPath: markdownFile.repositoryPath.normalizedRelativePath(),
        savedAt: Date()
      )
    } else {
      store.scheduleSiteDraftFileAutosave(for: updatedDraft, immediate: true)
    }
    return true
  }

  func draftIsMaterializedInProject(
    _ draft: ArticleDraft,
    expectedRepositoryPath: String,
    expectedContentDigest: String,
    profile: SiteProfile
  ) -> Bool {
    guard !draft.isGeneralDraft,
      let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
      repositoryPath == expectedRepositoryPath.normalizedRelativePath(),
      let binding = draft.repositoryBinding,
      binding.identity == DraftRepositoryIdentity(profile: profile),
      binding.repositoryPath.normalizedRelativePath() == repositoryPath,
      let rootURL = profile.localRepositoryRootURL,
      let projectFileDigest = binding.projectFileContentDigest
    else {
      return false
    }
    let currentDraftDigest = draft.renderedRepositoryContentDigest(profile: profile)
    guard currentDraftDigest == expectedContentDigest,
      projectFileDigest == expectedContentDigest
    else {
      return false
    }

    let fileURL = rootURL.appendingPathComponent(repositoryPath)
    guard let fileData = try? Data(contentsOf: fileURL),
      let fileContents = String(data: fileData, encoding: .utf8)
    else {
      return false
    }
    return ArticleDraft.repositoryDocumentDigest(fileContents) == expectedContentDigest
  }

  /// A remote write may start only after the exact site draft has a current
  /// project binding and its Markdown exists in the configured checkout.
  @discardableResult
  func ensureDraftMaterializedForRemotePublish(
    package: PublishPackage,
    profile: SiteProfile,
    store: WorkbenchStore
  ) async -> Bool {
    guard let markdownFile = package.markdownFile,
      markdownFile.operation == .upsert,
      let markdownContent = markdownFile.content
    else {
      setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return false
    }
    let expectedRepositoryPath = markdownFile.repositoryPath.normalizedRelativePath()
    let expectedContentDigest = ArticleDraft.repositoryDocumentDigest(markdownContent)
    let draftID = package.draftID
    guard let draft = drafts.first(where: { $0.id == draftID }), !draft.isGeneralDraft else {
      setPublishActionMessage(CoreL10n.text("找不到要加入项目的草稿。"), status: .warning)
      return false
    }
    guard draft.renderedRepositoryContentDigest(profile: profile) == expectedContentDigest else {
      setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return false
    }
    if draftIsMaterializedInProject(
      draft,
      expectedRepositoryPath: expectedRepositoryPath,
      expectedContentDigest: expectedContentDigest,
      profile: profile
    ) {
      return true
    }

    // A queued autosave may already be refreshing these bytes. Let it finish
    // before issuing a second write, then re-check the full binding/disk proof.
    await store.waitForPendingSiteDraftFileWrites()
    if let refreshed = drafts.first(where: { $0.id == draftID }),
      draftIsMaterializedInProject(
        refreshed,
        expectedRepositoryPath: expectedRepositoryPath,
        expectedContentDigest: expectedContentDigest,
        profile: profile
      )
    {
      return true
    }

    guard let refreshed = drafts.first(where: { $0.id == draftID }),
      refreshed.renderedRepositoryContentDigest(profile: profile) == expectedContentDigest
    else {
      setPublishActionMessage(
        CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。"),
        status: .warning
      )
      return false
    }

    let didWrite = await store.writeSiteDraftToProject(draftID: draftID)
    guard didWrite,
      let materialized = drafts.first(where: { $0.id == draftID }),
      draftIsMaterializedInProject(
        materialized,
        expectedRepositoryPath: expectedRepositoryPath,
        expectedContentDigest: expectedContentDigest,
        profile: profile
      )
    else {
      if didWrite {
        setPublishActionMessage(
          CoreL10n.format(
            "站点草稿写入项目失败：%@",
            CoreL10n.text("待发布文件已变化，请重新打开确认页审阅完整清单。")
          ),
          status: .failure
        )
      }
      return false
    }
    return true
  }

  public func profile(for draft: ArticleDraft) -> SiteProfile {
    if draft.isGeneralDraft {
      return activeProfile
    }
    return profiles.first { $0.id == draft.siteProfileID } ?? activeProfile
  }

  public func profile(for record: ReleaseRecord) -> SiteProfile {
    if let profileID = record.siteProfileID,
      let profile = profiles.first(where: { $0.id == profileID })
    {
      return profile
    }
    return activeProfile
  }

  public func profile(for package: PublishPackage) -> SiteProfile {
    drafts.first { $0.id == package.draftID }.map { profile(for: $0) } ?? activeProfile
  }

  public func blockingLocalPublishIssues(
    package: PublishPackage,
    preview: LocalPublishPreview,
    includeRepositoryReadiness: Bool,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    blockingLocalPublishIssues(
      preview: preview,
      draftIssues: draftPreflightIssues(
        package: package,
        includeRepositoryReadiness: includeRepositoryReadiness,
        store: store
      )
    )
  }

  public func makeLocalPublishReadiness(
    package: PublishPackage,
    profile: SiteProfile,
    preview: LocalPublishPreview,
    store: WorkbenchStore
  ) -> LocalPublishReadiness {
    let draftIssuesWithoutRepository = draftPreflightIssues(
      package: package,
      includeRepositoryReadiness: false,
      store: store
    )
    let draftIssuesWithRepository = draftPreflightIssues(
      package: package,
      includeRepositoryReadiness: true,
      store: store
    )
    return makeLocalPublishReadiness(
      package: package,
      profile: profile,
      preview: preview,
      draftIssuesWithoutRepository: draftIssuesWithoutRepository,
      draftIssuesWithRepository: draftIssuesWithRepository,
      store: store
    )
  }

  func makeLocalPublishReadiness(
    package: PublishPackage,
    profile: SiteProfile,
    preview: LocalPublishPreview,
    draftIssuesWithoutRepository: [PreflightIssue],
    draftIssuesWithRepository: [PreflightIssue],
    store: WorkbenchStore
  ) -> LocalPublishReadiness {
    var repositoryBlockingIssues: [PreflightIssue] = []
    if profile.purpose.requiresRepositoryReadiness {
      if let repositoryReport = store.repositoryReport(for: profile) {
        if let missingGitIssue = repositoryReport.preflightIssues.first(where: {
          $0.title == CoreL10n.text("未发现 .git")
        }) {
          repositoryBlockingIssues.append(missingGitIssue)
        }
      } else {
        repositoryBlockingIssues.append(
          PreflightIssue(
            severity: .error,
            title: CoreL10n.text("仓库尚未扫描"),
            message: CoreL10n.text("请先刷新仓库状态，再执行提交或推送。"),
            field: "repository"
          )
        )
      }
    }
    let remoteWarningIssues = remotePublishRiskService.issues(
      package: package,
      repositoryReport: store.repositoryReport(for: profile)
    )
    return PublishingReadinessProjection.makeReadiness(
      package: package,
      preview: preview,
      draftIssuesWithoutRepository: draftIssuesWithoutRepository,
      draftIssuesWithRepository: draftIssuesWithRepository,
      repositoryBlockingIssues: repositoryBlockingIssues,
      remoteWarningIssues: remoteWarningIssues
    )
  }

  private func draftPreflightIssues(
    package: PublishPackage,
    includeRepositoryReadiness: Bool,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    store.drafts.first(where: { $0.id == package.draftID })
      .map {
        store.preflightIssues(for: $0, includeRepositoryReadiness: includeRepositoryReadiness)
      }
      ?? []
  }

  private func blockingLocalPublishIssues(
    preview: LocalPublishPreview,
    draftIssues: [PreflightIssue]
  ) -> [PreflightIssue] {
    PublishingReadinessProjection.blockingIssues(
      preview: preview,
      draftIssues: draftIssues
    )
  }

  public func blockedLocalPublishMessage(action: String, issues: [PreflightIssue]) -> String {
    let localizedAction = CoreL10n.text(action)
    let summary = issues.prefix(3).map { issue in
      issue.message.nilIfEmpty.map { CoreL10n.format("%@（%@）", issue.title, $0) } ?? issue.title
    }.joined(separator: CoreL10n.text("、"))
    return summary.isEmpty
      ? CoreL10n.format("已停止%@，请先处理发布检查错误。", localizedAction)
      : CoreL10n.format("已停止%@：%@", localizedAction, summary)
  }

  public func runPreflight(store: WorkbenchStore) {
    guard let selectedDraft = store.selectedDraft else {
      preflightIssues = []
      return
    }
    preflightIssues = preflightIssues(for: selectedDraft, store: store)
  }

  public func refreshPublishPreview(for draft: ArticleDraft? = nil, store: WorkbenchStore) {
    let targetDraftID = draft?.id ?? store.selectedDraftID
    guard let targetDraftID else {
      cancelPublishPreviewRefresh()
      projectSelectedDraftPublishPreview()
      refreshLocalSitePreviewPlan(for: store.activeProfile)
      return
    }

    store.flushDraftBodyEditorBuffer(for: targetDraftID)
    guard let targetDraft = store.draft(for: targetDraftID) else {
      cancelPublishPreviewRefresh(for: targetDraftID)
      removeDraftPublishPreviewSnapshot(for: targetDraftID)
      forgetDraftPublishPreviewInputBaseline(for: targetDraftID)
      return
    }

    cancelPublishPreviewRefresh(for: targetDraftID)
    guard !targetDraft.isGeneralDraft else {
      removeDraftPublishPreviewSnapshot(for: targetDraftID)
      forgetDraftPublishPreviewInputBaseline(for: targetDraftID)
      projectSelectedDraftPublishPreview()
      return
    }

    let profile = store.profile(for: targetDraft)
    if store.selectedDraftID == targetDraftID && store.activeProfileID == profile.id {
      refreshLocalSitePreviewPlan(for: profile)
    }
    let baseline = makeDraftPublishPreviewInputBaseline(
      for: targetDraft,
      store: store,
      bodyRevision: store.draftBodyEditorBuffer(for: targetDraftID).revision
    )
    let allDrafts = store.drafts
      .filter { $0.belongs(toSiteProfileID: profile.id) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let duplicateIndex = PreflightDuplicateIndex(drafts: allDrafts, profile: profile)
    let draftIssuesWithoutRepository = preflightService.run(
      draft: baseline.draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: baseline.repositoryReport,
      includeRepositoryReadiness: false,
      duplicateIndex: duplicateIndex
    )
    let draftIssuesWithRepository = preflightService.run(
      draft: baseline.draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: baseline.repositoryReport,
      includeRepositoryReadiness: true,
      duplicateIndex: duplicateIndex
    )
    let package = publishPackageBuilder.build(
      draft: baseline.draft,
      profile: profile
    )
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    let readiness = makeLocalPublishReadiness(
      package: package,
      profile: profile,
      preview: preview,
      draftIssuesWithoutRepository: draftIssuesWithoutRepository,
      draftIssuesWithRepository: draftIssuesWithRepository,
      store: store
    )
    let remotePreview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: preferredRemoteRepositoryPublishMode(for: profile),
      localPreview: preview,
      draftIssuesWithRepository: draftIssuesWithRepository,
      repositoryReport: baseline.repositoryReport,
      tokenAvailability: baseline.tokenAvailability,
      accessCheck: baseline.remoteRepositoryAccessCheck,
      store: store
    )
    let snapshot = DraftPublishPreviewSnapshot(
      context: baseline.context,
      publishPackage: package,
      localPublishPreview: preview,
      localPublishReadiness: readiness,
      remotePublishPreview: remotePreview,
      remoteReviewDraft: remoteReviewDraftBuilder.build(
        package: package,
        profile: profile
      )
    )
    rememberDraftPublishPreviewInputBaseline(baseline, for: targetDraftID)
    _ = installDraftPublishPreviewSnapshot(snapshot, for: targetDraftID)
  }

  public func refreshPublishPreview(for draftID: UUID, store: WorkbenchStore) {
    guard let draft = store.draft(for: draftID) else {
      cancelPublishPreviewRefresh(for: draftID)
      removeDraftPublishPreviewSnapshot(for: draftID)
      forgetDraftPublishPreviewInputBaseline(for: draftID)
      return
    }
    refreshPublishPreview(for: draft, store: store)
  }

  public func refreshBatchPublishPlan(store: WorkbenchStore) {
    cancelBatchPublishPlanRefresh()
    let cleanupRequests = pendingRemoteRepositoryCleanupRequests(profileID: store.activeProfileID)
    let plan = batchPublishPlanService.plan(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      repositoryReport: store.repositoryReport
    )
    batchPublishPlan = plan
    batchRemotePublishPreviewSnapshot = remoteRepositoryPublishPreview(
      for: plan,
      cleanupRequests: cleanupRequests,
      store: store
    )
    batchRemoteReviewDraft = remotePublishPackage(
      for: plan,
      cleanupRequests: cleanupRequests
    ).map { remoteReviewDraftBuilder.build(package: $0, profile: store.activeProfile) }
  }

  public func publishingPackage(for draft: ArticleDraft, store: WorkbenchStore) -> PublishPackage {
    publishPackageBuilder.build(draft: draft, profile: store.profile(for: draft))
  }

  public func localPublishPreview(for draft: ArticleDraft, store: WorkbenchStore)
    -> LocalPublishPreview
  {
    let package = publishingPackage(for: draft, store: store)
    return localPublishPreviewService.preview(package: package, profile: store.profile(for: draft))
  }

  public func remoteReviewDraft(for draft: ArticleDraft, store: WorkbenchStore) -> RemoteReviewDraft
  {
    remoteReviewDraftBuilder.build(
      package: publishingPackage(for: draft, store: store), profile: store.profile(for: draft))
  }

  public func draftComparisonContent(for draft: ArticleDraft, store: WorkbenchStore)
    -> DraftComparisonContent
  {
    let package = publishingPackage(for: draft, store: store)
    return DraftComparisonContent(
      repositoryPath: package.markdownPath,
      localContent: package.markdownFile?.content
    )
  }

  public func publishingAIPrompt(for draft: ArticleDraft, store: WorkbenchStore) -> String {
    let profile = store.profile(for: draft)
    let package = publishingPackage(for: draft, store: store)
    let issues =
      preflightIssues(for: draft, store: store)
      + remotePublishRiskService.issues(
        package: package,
        repositoryReport: store.repositoryReport(for: profile)
      )
    let localPreview = localPublishPreview(for: draft, store: store)
    let sitePreview = localSitePreviewPlan(for: draft, store: store)
    let imageReport = store.imageWorkbenchReport(for: draft)
    let reviewDraft = remoteReviewDraft(for: draft, store: store)
    return publishingAIPrompt(
      draft: draft,
      profile: profile,
      package: package,
      issues: issues,
      localPreview: localPreview,
      sitePreview: sitePreview,
      imageReport: imageReport,
      reviewDraft: reviewDraft
    )
  }

  func publishingAIPrompt(
    from artifacts: AIPublishingRequestArtifacts,
    store: WorkbenchStore
  ) -> String {
    let issues =
      artifacts.preflightIssues
      + remotePublishRiskService.issues(
        package: artifacts.publishPackage,
        repositoryReport: store.repositoryReport(for: artifacts.profile)
      )
    return publishingAIPrompt(
      draft: artifacts.draft,
      profile: artifacts.profile,
      package: artifacts.publishPackage,
      issues: issues,
      localPreview: artifacts.workflowContext.publishPreview,
      sitePreview: artifacts.workflowContext.localSitePreviewPlan,
      imageReport: artifacts.workflowContext.imageReport,
      reviewDraft: artifacts.remoteReviewDraft
    )
  }

  private func publishingAIPrompt(
    draft: ArticleDraft,
    profile: SiteProfile,
    package: PublishPackage,
    issues: [PreflightIssue],
    localPreview: LocalPublishPreview?,
    sitePreview: LocalSitePreviewPlan?,
    imageReport: ImageWorkbenchReport?,
    reviewDraft: RemoteReviewDraft
  ) -> String {
    var lines: [String] = [
      "# 发布协助请求",
      "",
      "站点：\(profile.name)",
      "标题：\(draft.title)",
      "发布路径：\(package.markdownPath)",
      "",
      "## 摘要",
      draft.summary.nilIfEmpty ?? "无摘要",
      "",
      "## 发布检查"
    ]
    if issues.isEmpty {
      lines.append("- 无阻断项")
    } else {
      lines.append(
        contentsOf: issues.map { "- [\($0.severity.displayName)] \($0.title)：\($0.message)" })
    }
    lines.append(contentsOf: [
      "",
      "## 发布准备建议",
      "Mac 发布上下文：",
      "本地 diff：\(localPreview?.changedFileDiffs.count ?? 0) 个待写入变化。",
      "本地预览：\(sitePreview?.command ?? "尚未配置本地预览命令。")",
      "图片检查：\(imageReport?.items.count ?? 0) 张，缺 alt \(imageReport?.missingAltTextCount ?? 0) 张，缺源图 \(imageReport?.missingSourceCount ?? 0) 张。",
      "",
      "## PR/MR 描述草稿",
      "标题：\(reviewDraft.title)",
      reviewDraft.body,
    ])
    lines.append("")
    lines.append("## 正文")
    lines.append(draft.bodyMarkdown)
    return lines.joined(separator: "\n")
  }

  public func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool = true,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    if draft.isGeneralDraft {
      return [generalDraftPublishingIssue]
    }
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: draft.siteProfileID) }
    let profile = store.profile(for: draft)
    let baseIssues = preflightService.run(
      draft: draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness
    )
    return store.localSiteLinkAuditReport(
      drafts: allDrafts,
      profile: profile
    ).mergingPreflightIssues(baseIssues, for: draft)
  }

  func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool,
    allDrafts: [ArticleDraft],
    duplicateIndex: PreflightDuplicateIndex,
    linkAuditReport: SiteLinkAuditReport? = nil,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    if draft.isGeneralDraft {
      return [generalDraftPublishingIssue]
    }
    let profile = store.profile(for: draft)
    let baseIssues = preflightService.run(
      draft: draft,
      allDrafts: allDrafts,
      profile: profile,
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness,
      duplicateIndex: duplicateIndex
    )
    let resolvedLinkAuditReport =
      linkAuditReport
      ?? store.localSiteLinkAuditReport(drafts: allDrafts, profile: profile)
    return resolvedLinkAuditReport.mergingPreflightIssues(baseIssues, for: draft)
  }

  public func sitePreflightIssues(store: WorkbenchStore) -> [PreflightIssue] {
    let profile = store.activeProfile
    guard profile.purpose.requiresRepositoryReadiness else { return [] }
    if profile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      return [
        PreflightIssue(
          severity: .warning,
          title: CoreL10n.text("未选择本地仓库"),
          message: profile.purpose.repositoryRootMissingMessage,
          field: "repository"
        )
      ]
    }
    return store.repositoryReport(for: profile)?.preflightIssues(
      requiringDeploymentReadiness: profile.purpose.requiresDeploymentReadiness
    ) ?? []
  }

  public func contentHealthSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    contentHealthReport(store: store).draftSummaries
  }

  public func contentHealthReport(store: WorkbenchStore) -> ContentHealthReport {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    return contentHealthReportService.report(
      drafts: drafts,
      profile: profile,
      sitePreflightIssues: sitePreflightIssues(store: store),
      presentations: contentHealthPresentations(store: store),
      linkAuditReport: store.localSiteLinkAuditReport(
        drafts: drafts,
        profile: profile
      )
    )
  }

  public func contentHealthReportAsync(store: WorkbenchStore) async throws -> ContentHealthReport {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let siteIssues = sitePreflightIssues(store: store)
    let presentations = contentHealthPresentations(store: store)
    let linkAuditReport = try await store.localSiteLinkAuditReportAsync(
      drafts: drafts,
      profile: profile
    )
    return try await contentHealthReportService.reportAsync(
      drafts: drafts,
      profile: profile,
      sitePreflightIssues: siteIssues,
      presentations: presentations,
      linkAuditReport: linkAuditReport,
      validatesExternalLinks: false
    )
  }

  private func contentHealthPresentations(store: WorkbenchStore) -> [UUID:
    ContentHealthDraftPresentation]
  {
    Dictionary(
      uniqueKeysWithValues: store.visibleDrafts.map { draft in
        let display = store.privateContentDisplay(for: draft)
        let markdownPath =
          display.isMasked
          ? "内容已遮挡，打开文章或关闭私密遮挡后查看。"
          : store.profile(for: draft).markdownPath(for: draft)
        return (
          draft.id, ContentHealthDraftPresentation(title: display.title, markdownPath: markdownPath)
        )
      })
  }

  public func publicRiskSummary(store: WorkbenchStore) -> PublicRiskSummary {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: profile.id) }
    let duplicateIndex = PreflightDuplicateIndex(drafts: allDrafts, profile: profile)
    let linkAuditReport = store.localSiteLinkAuditReport(
      drafts: allDrafts,
      profile: profile
    )
    let summaries = drafts.map {
      DraftPreflightSummary(
        draftID: $0.id,
        draftTitle: $0.title,
        markdownPath: store.profile(for: $0).markdownPath(for: $0),
        issues: preflightIssues(
          for: $0,
          includeRepositoryReadiness: false,
          allDrafts: allDrafts,
          duplicateIndex: duplicateIndex,
          linkAuditReport: linkAuditReport,
          store: store
        )
      )
    }
    return ContentHealthProjection.publicRiskSummary(from: summaries)
  }

  public func publicRiskSummary(for draft: ArticleDraft, store: WorkbenchStore) -> PublicRiskSummary
  {
    let summary = DraftPreflightSummary(
      draftID: draft.id,
      draftTitle: draft.title,
      markdownPath: store.profile(for: draft).markdownPath(for: draft),
      issues: preflightIssues(for: draft, includeRepositoryReadiness: false, store: store)
    )
    return ContentHealthProjection.publicRiskSummary(from: [summary])
  }

  public func publicRiskDraftSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: profile.id) }
    let duplicateIndex = PreflightDuplicateIndex(drafts: allDrafts, profile: profile)
    let linkAuditReport = store.localSiteLinkAuditReport(
      drafts: allDrafts,
      profile: profile
    )
    return drafts.map {
      DraftPreflightSummary(
        draftID: $0.id,
        draftTitle: $0.title,
        markdownPath: store.profile(for: $0).markdownPath(for: $0),
        issues: preflightIssues(
          for: $0,
          includeRepositoryReadiness: false,
          allDrafts: allDrafts,
          duplicateIndex: duplicateIndex,
          linkAuditReport: linkAuditReport,
          store: store
        )
      )
    }
  }

  public func aiFixQueueItems(store: WorkbenchStore) -> [AIPublishingFixQueueItem] {
    aiFixQueueService.items(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      summaries: contentHealthSummaries(store: store)
    )
  }

  public func remoteRepositoryPublishPreview(for draft: ArticleDraft, store: WorkbenchStore)
    -> RemoteRepositoryPublishPreview
  {
    remoteRepositoryPublishPreview(
      package: store.publishingPackage(for: draft),
      profile: store.profile(for: draft),
      mode: preferredRemoteRepositoryPublishMode(for: store.profile(for: draft)),
      store: store
    )
  }

  public func remoteRepositoryPublishPreview(
    for plan: BatchPublishPlan,
    cleanupRequests: [DraftRepositoryCleanupRequest]? = nil,
    store: WorkbenchStore
  ) -> RemoteRepositoryPublishPreview? {
    let cleanupRequests =
      cleanupRequests
      ?? pendingRemoteRepositoryCleanupRequests(profileID: plan.profileID)
    let cleanupPaths = Set(cleanupRequests.map { $0.repositoryPath.normalizedRelativePath() })
    return remotePublishPackage(for: plan, cleanupRequests: cleanupRequests).map {
      remoteRepositoryPublishPreview(
        package: $0,
        profile: store.activeProfile,
        mode: preferredRemoteRepositoryPublishMode(for: store.activeProfile),
        extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
        forcedChangedPaths: cleanupPaths,
        store: store
      )
    }
  }

  public func remotePublishPackage(
    for plan: BatchPublishPlan,
    cleanupRequests: [DraftRepositoryCleanupRequest] = []
  ) -> PublishPackage? {
    let publishableItems = plan.remotePublishableItems
    let cleanupPackage = draftLifecycleService.cleanupPackage(for: cleanupRequests)
    let files = deduplicatedBatchPublishFiles(
      publishableItems.flatMap(\.package.files) + (cleanupPackage?.files ?? [])
    )
    guard !files.isEmpty,
      let draftID = publishableItems.first?.draftID ?? cleanupRequests.first?.draftID,
      let markdownPath = publishableItems.first?.markdownPath
        ?? cleanupRequests.first?.repositoryPath
    else {
      return nil
    }
    let publishCount = publishableItems.count
    let cleanupCount = cleanupRequests.count
    let title: String
    let commitMessage: String
    let reviewTitle: String
    if cleanupCount == 0 {
      title = "批量发布 \(publishCount) 篇文章"
      commitMessage = "Publish: \(publishCount) articles"
      reviewTitle = "Publish \(publishCount) articles"
    } else if publishCount == 0 {
      title = "批量下线 \(cleanupCount) 篇文章"
      commitMessage = "Delete: \(cleanupCount) articles"
      reviewTitle = "Delete \(cleanupCount) articles"
    } else {
      title = "发布 \(publishCount) 篇并下线 \(cleanupCount) 篇文章"
      commitMessage = "Publish: \(publishCount) articles; delete: \(cleanupCount) articles"
      reviewTitle = "Publish \(publishCount) and delete \(cleanupCount) articles"
    }
    return PublishPackage(
      draftID: draftID,
      title: title,
      draftSummary: nil,
      draftCoverAltText: nil,
      markdownPath: markdownPath,
      files: files,
      commitMessage: commitMessage,
      reviewBranchName: "publish/batch-\(Self.batchPublishDateToken())",
      reviewTitle: reviewTitle,
      reviewChecklist: [
        "批量发布清单已确认",
        "图片路径和 alt/caption 已检查",
        "公开风险和私密内容已确认",
        "已确认文章仍在回收站或已永久删除",
        "已核对待删除的仓库路径",
      ]
    )
  }

  public func remoteRepositoryPublishPreview(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    extraWarningIssues: [PreflightIssue] = [],
    localPreview: LocalPublishPreview? = nil,
    forcedChangedPaths: Set<String> = [],
    repositoryReport: RepositoryScanReport? = nil,
    tokenAvailability: KeychainTokenAvailability? = nil,
    accessCheck: RemoteRepositoryAccessCheck? = nil,
    store: WorkbenchStore
  ) -> RemoteRepositoryPublishPreview {
    let preview =
      localPreview ?? localPublishPreviewService.preview(package: package, profile: profile)
    let draftIssuesWithRepository = draftPreflightIssues(
      package: package,
      includeRepositoryReadiness: true,
      store: store
    )
    return remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: extraWarningIssues,
      localPreview: preview,
      draftIssuesWithRepository: draftIssuesWithRepository,
      forcedChangedPaths: forcedChangedPaths,
      repositoryReport: repositoryReport,
      tokenAvailability: tokenAvailability,
      accessCheck: accessCheck,
      store: store
    )
  }

  func remoteRepositoryPublishPreview(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    extraWarningIssues: [PreflightIssue] = [],
    localPreview: LocalPublishPreview,
    draftIssuesWithRepository: [PreflightIssue],
    forcedChangedPaths: Set<String> = [],
    repositoryReport: RepositoryScanReport? = nil,
    tokenAvailability: KeychainTokenAvailability? = nil,
    accessCheck: RemoteRepositoryAccessCheck? = nil,
    store: WorkbenchStore
  ) -> RemoteRepositoryPublishPreview {
    let repositoryName = profile.repositoryDisplayName
    let blockingIssues = blockingLocalPublishIssues(
      preview: localPreview,
      draftIssues: draftIssuesWithRepository
    )
    let remoteRiskAssessment = remotePublishRiskService.assessment(
      package: package,
      repositoryReport: repositoryReport ?? store.repositoryReport(for: profile)
    )
    let remoteWarnings = remotePublishRiskService.issues(
      for: remoteRiskAssessment,
      includeUnknownState: true
    )
    let directConflictBlockingIssues =
      mode == .directCommit && remoteRiskAssessment.state == .conflict
      ? remoteWarnings
      : []
    let visibleRemoteWarnings = directConflictBlockingIssues.isEmpty ? remoteWarnings : []
    let resolvedAccessCheck =
      accessCheck
      ?? freshRemoteRepositoryAccessCheckForPreview(profile: profile, store: store)
    let resolvedTokenAvailability =
      tokenAvailability
      ?? repositoryTokenAvailabilityForPreview(profile: profile, store: store)
    let tokenAccessBlockingIssues: [PreflightIssue] =
      resolvedTokenAvailability
      .accessFailureMessage
      .map { failureMessage in
        [
          PreflightIssue(
            severity: .error,
            title: CoreL10n.text("Token 状态读取失败"),
            message: CoreL10n.format(
              "仓库 Token 状态读取失败：%@",
              failureMessage
            ),
            field: "repositoryToken"
          )
        ]
      } ?? []
    let permissionWarnings: [PreflightIssue] =
      resolvedTokenAvailability.hasToken && resolvedAccessCheck == nil
      ? [
        PreflightIssue(
          severity: .warning,
          title: CoreL10n.text("Token 权限未检查"),
          message: CoreL10n.format(
            "当前 Token 尚未针对 %@ 完成写入权限检查，请先检查后再发布。",
            repositoryName
          ),
          field: "repositoryToken"
        )
      ]
      : []
    let localChangedPaths = localPreview.changedFileDiffs.map(\.path)
    let changedPaths =
      localChangedPaths
      + forcedChangedPaths
      .subtracting(Set(localChangedPaths.map { $0.normalizedRelativePath() }))
      .sorted()
    let branchName: String
    switch mode {
    case .directCommit:
      branchName = profile.branch
    case .reviewRequest:
      branchName = package.reviewBranchName
    case .previewBranch:
      branchName = package.draftPreviewBranchName
    }
    return RemoteRepositoryPublishPreview(
      provider: profile.repositoryProvider,
      repositoryName: repositoryName,
      mode: mode,
      branchName: branchName,
      targetBranch: profile.branch,
      changedPaths: changedPaths,
      remoteConflictPaths: remoteRiskAssessment.conflictPaths,
      remoteRiskState: remoteRiskAssessment.state,
      hasToken: resolvedTokenAvailability.hasToken,
      tokenAccessFailureMessage: resolvedTokenAvailability.accessFailureMessage,
      accessCheck: resolvedAccessCheck,
      blockingIssues: blockingIssues + tokenAccessBlockingIssues + directConflictBlockingIssues,
      warningIssues: visibleRemoteWarnings + permissionWarnings + extraWarningIssues
    )
  }

  public func batchRemoteRepositoryPublishWarningIssues(for plan: BatchPublishPlan)
    -> [PreflightIssue]
  {
    plan.items.flatMap { item in
      item.allIssues
        .filter { $0.severity == .warning }
        .map { issue in
          var titledIssue = issue
          titledIssue.title = CoreL10n.format("%@：%@", item.draftTitle, issue.title)
          return titledIssue
        }
    }
  }

  public func preferredLocalGitPublishMode(for profile: SiteProfile) -> LocalGitPublishMode {
    profile.repositoryPublishStrategy == .direct ? .directCommit : .reviewBranch
  }

  public func preferredRemoteRepositoryPublishMode(for profile: SiteProfile)
    -> RemoteRepositoryPublishMode
  {
    profile.repositoryPublishStrategy == .direct ? .directCommit : .reviewRequest
  }

  func remotePublishCompletionFeedback(
    mode: RemoteRepositoryPublishMode,
    operationSummary: String,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> PublishActionFeedback {
    switch mode {
    case .reviewRequest:
      return PublishActionFeedback(
        message: CoreL10n.format("%@；PR/MR 已创建，等待合并，尚未部署。", operationSummary),
        status: .information
      )
    case .previewBranch:
      return PublishActionFeedback(
        message: CoreL10n.format("%@；预览分支已推送，不影响正式分支。", operationSummary),
        status: .information
      )
    case .directCommit:
      switch deploymentStatus?.level {
      case .success:
        guard deploymentStatus?.attributionVerified == true else {
          return PublishActionFeedback(
            message: CoreL10n.format(
              "%@；部署端点可达，但没有绑定当前 commit 的证据。",
              operationSummary
            ),
            status: .warning
          )
        }
        return PublishActionFeedback(
          message: CoreL10n.format("%@；部署已验证。", operationSummary),
          status: .success
        )
      case .running:
        return PublishActionFeedback(
          message: CoreL10n.format("%@；部署仍在进行。", operationSummary),
          status: .inProgress
        )
      case .failed:
        return PublishActionFeedback(
          message: CoreL10n.format("%@；目标分支已提交，但部署检查失败。", operationSummary),
          status: .failure
        )
      case .unknown:
        return PublishActionFeedback(
          message: CoreL10n.format("%@；目标分支已提交，但部署状态尚未确认。", operationSummary),
          status: .warning
        )
      case nil:
        return PublishActionFeedback(
          message: CoreL10n.format("%@；目标分支已提交，部署尚未验证。", operationSummary),
          status: .warning
        )
      }
    }
  }

  func remotePublishCompletedProgressMessage(
    mode: RemoteRepositoryPublishMode,
    deploymentStatus: DeploymentStatusSnapshot?
  ) -> String {
    guard mode == .directCommit else { return mode.completedProgressMessage }
    switch deploymentStatus?.level {
    case .success:
      return deploymentStatus?.attributionVerified == true
        ? CoreL10n.text("目标分支提交完成、部署已验证")
        : mode.completedProgressMessage
    case .running:
      return CoreL10n.text("目标分支提交完成、部署进行中")
    case .failed:
      return CoreL10n.text("目标分支提交完成、部署检查失败")
    case .unknown, nil:
      return mode.completedProgressMessage
    }
  }

  @discardableResult
  public func markDraftsAsPublishedIfDirectRemoteCommit(
    mode: RemoteRepositoryPublishMode,
    draftIDs: [UUID]
  ) -> Bool {
    guard mode == .directCommit else { return false }
    let now = Date()
    let updatedDrafts = drafts.map { draft in
      guard draftIDs.contains(draft.id), !draft.draft else { return draft }
      var updatedDraft = draft
      updatedDraft.status = .published
      updatedDraft.markUpdated(at: now, replacing: draft)
      return updatedDraft
    }
    let didChange = updatedDrafts != drafts
    if didChange {
      drafts = updatedDrafts
    }
    for draftID in draftIDs {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
    return didChange
  }

  func markDraftsRepositorySyncState(
    _ state: DraftRepositorySyncState,
    draftIDs: Set<UUID>
  ) {
    guard !draftIDs.isEmpty else { return }
    let updatedDrafts = drafts.map { draft in
      guard draftIDs.contains(draft.id), draft.repositoryPath?.nilIfEmpty != nil else {
        return draft
      }
      var updatedDraft = draft
      updatedDraft.markRepositorySyncState(state)
      guard updatedDraft != draft else { return draft }
      updatedDraft.markUpdated(at: draft.updatedAt, replacing: draft)
      return updatedDraft
    }
    if updatedDrafts != drafts {
      drafts = updatedDrafts
    }
    for draftID in draftIDs {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
  }

  func markRemotePublishReviewSuccess(packages: [PublishPackage]) {
    let draftIDs = Set(packages.map(\.draftID))
    let updatedDrafts = drafts.map { draft in
      guard draftIDs.contains(draft.id), draft.repositoryPath?.nilIfEmpty != nil else {
        return draft
      }
      var updatedDraft = draft
      updatedDraft.markRepositoryAwaitingReview(profile: profile(for: updatedDraft))
      guard updatedDraft != draft else { return draft }
      updatedDraft.markUpdated(at: draft.updatedAt, replacing: draft)
      return updatedDraft
    }
    if updatedDrafts != drafts {
      drafts = updatedDrafts
    }
    for draftID in draftIDs {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
  }

  func markRemotePublishFailure(packages: [PublishPackage], error: Error) {
    let conflictPath: String?
    switch error {
    case let RemoteRepositoryPublishError.untrackedRemoteFile(path, _),
      let RemoteRepositoryPublishError.remoteVersionConflict(path, _, _):
      conflictPath = path.normalizedRelativePath()
    default:
      conflictPath = nil
    }

    if let conflictPath {
      let conflictedIDs = Set(
        packages.compactMap { package -> UUID? in
          package.files.contains {
            $0.repositoryPath.normalizedRelativePath() == conflictPath
          } ? package.draftID : nil
        })
      markDraftsRepositorySyncState(.diverged, draftIDs: conflictedIDs)
      markDraftsRepositorySyncState(
        .failed,
        draftIDs: Set(packages.map(\.draftID)).subtracting(conflictedIDs)
      )
    } else {
      markDraftsRepositorySyncState(.failed, draftIDs: Set(packages.map(\.draftID)))
    }
  }

  func confirmLocalGitPublishLifecycle(
    package: PublishPackage,
    mode: LocalGitPublishMode
  ) {
    guard mode == .directCommit,
      let index = drafts.firstIndex(where: { $0.id == package.draftID })
    else {
      return
    }
    let previousDraft = drafts[index]
    let profile = profile(for: previousDraft)
    let confirmedPath = package.markdownPath.normalizedRelativePath()
    let renderedDigest =
      package.markdownFile?.content
      .map(ArticleDraft.repositoryDocumentDigest)
      ?? previousDraft.renderedRepositoryContentDigest(profile: profile)
    var updatedDraft = previousDraft
    updatedDraft.recordProjectFile(
      profile: profile,
      repositoryPath: confirmedPath,
      renderedContentDigest: renderedDigest
    )
    updatedDraft.repositoryImportFingerprint = updatedDraft.repositoryContentFingerprint
    if updatedDraft != previousDraft {
      updatedDraft.markUpdated(at: previousDraft.updatedAt, replacing: previousDraft)
      drafts[index] = updatedDraft
    }
    removeDraftPublishPreviewSnapshot(for: package.draftID)
  }

  func confirmDirectRemotePublishLifecycle(
    packages: [PublishPackage],
    result: RemoteRepositoryPublishResult
  ) {
    guard result.mode == .directCommit else { return }
    let packagesByDraftID = Dictionary(uniqueKeysWithValues: packages.map { ($0.draftID, $0) })
    let now = Date()
    let updatedDrafts = drafts.map { draft in
      guard let package = packagesByDraftID[draft.id] else { return draft }
      var updated = draft
      updated.attachments = updated.attachments.map { attachment in
        guard let remoteVersion = result.remoteVersion(for: attachment.repositoryPath) else {
          return attachment
        }
        var confirmedAttachment = attachment
        confirmedAttachment.repositorySHA = remoteVersion
        return confirmedAttachment
      }
      let profile = profile(for: updated)
      let confirmedPath = package.markdownPath.normalizedRelativePath()
      let renderedDigest =
        package.markdownFile?.content
        .map(ArticleDraft.repositoryDocumentDigest)
        ?? updated.renderedRepositoryContentDigest(profile: profile)
      if let remoteVersion = result.remoteVersion(for: package.markdownPath) {
        updated.confirmRepositoryBinding(
          profile: profile,
          repositoryPath: confirmedPath,
          remoteRevision: remoteVersion,
          renderedContentDigest: renderedDigest,
          verifiedAt: now
        )
      } else {
        // A sparse legacy result must never erase a known CAS baseline. Newer
        // services return a version for every verified unchanged upsert.
        updated.recordProjectFile(
          profile: profile,
          repositoryPath: confirmedPath,
          renderedContentDigest: renderedDigest
        )
        updated.repositoryImportFingerprint = updated.repositoryContentFingerprint
      }
      guard updated != draft else { return draft }
      updated.markUpdated(at: draft.updatedAt, replacing: draft)
      return updated
    }
    if updatedDrafts != drafts {
      drafts = updatedDrafts
    }
    for draftID in packagesByDraftID.keys {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
  }

  public func partialRemoteRepositoryPublishFailure(from error: Error)
    -> RemoteRepositoryPublishResult?
  {
    guard
      case RemoteRepositoryPublishError.partialPublish(
        let provider,
        let mode,
        let branchName,
        let targetBranch,
        let changedPaths,
        let commitSHA,
        _
      ) = error
    else {
      return nil
    }
    return RemoteRepositoryPublishResult(
      provider: provider,
      mode: mode,
      branchName: branchName,
      targetBranch: targetBranch,
      changedPaths: changedPaths,
      commitSHA: commitSHA
    )
  }

}
