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
    if publishPackage?.draftID != selectedDraft.id {
      refreshPublishPreview(for: selectedDraft, store: store)
    }
    guard let publishPackage, publishPackage.draftID == selectedDraft.id else {
      return nil
    }
    return publishPackage
  }

  public func profile(for draft: ArticleDraft) -> SiteProfile {
    if draft.isGeneralDraft {
      return activeProfile
    }
    return profiles.first { $0.id == draft.siteProfileID } ?? activeProfile
  }

  public func profile(for record: ReleaseRecord) -> SiteProfile {
    if let profileID = record.siteProfileID, let profile = profiles.first(where: { $0.id == profileID }) {
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
        if let missingGitIssue = repositoryReport.preflightIssues.first(where: { $0.title == CoreL10n.text("未发现 .git") }) {
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
      .map { store.preflightIssues(for: $0, includeRepositoryReadiness: includeRepositoryReadiness) }
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
    cancelPublishPreviewRefresh()
    let selectedDraft = draft ?? store.selectedDraft
    let profile = selectedDraft.map { store.profile(for: $0) } ?? store.activeProfile
    refreshLocalSitePreviewPlan(for: profile)

    guard let selectedDraft else {
      publishPackage = nil
      localPublishPreview = nil
      localPublishReadiness = nil
      remotePublishPreviewSnapshot = nil
      return
    }
    guard !selectedDraft.isGeneralDraft else {
      publishPackage = nil
      localPublishPreview = nil
      localPublishReadiness = nil
      remotePublishPreviewSnapshot = nil
      remoteReviewDraft = nil
      return
    }
    let package = publishingPackage(for: selectedDraft, store: store)
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    let draftIssuesWithoutRepository = store.preflightIssues(
      for: selectedDraft,
      includeRepositoryReadiness: false
    )
    let draftIssuesWithRepository = store.preflightIssues(
      for: selectedDraft,
      includeRepositoryReadiness: true
    )
    publishPackage = package
    localPublishPreview = preview
    localPublishReadiness = makeLocalPublishReadiness(
      package: package,
      profile: profile,
      preview: preview,
      draftIssuesWithoutRepository: draftIssuesWithoutRepository,
      draftIssuesWithRepository: draftIssuesWithRepository,
      store: store
    )
    remotePublishPreviewSnapshot = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: preferredRemoteRepositoryPublishMode(for: profile),
      localPreview: preview,
      draftIssuesWithRepository: draftIssuesWithRepository,
      store: store
    )
    remoteReviewDraft = remoteReviewDraftBuilder.build(package: package, profile: profile)
  }

  public func refreshBatchPublishPlan(store: WorkbenchStore) {
    cancelBatchPublishPlanRefresh()
    let plan = batchPublishPlanService.plan(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      repositoryReport: store.repositoryReport
    )
    batchPublishPlan = plan
    batchRemotePublishPreviewSnapshot = remoteRepositoryPublishPreview(for: plan, store: store)
    batchRemoteReviewDraft = remoteReviewDraftBuilder.buildBatch(plan: plan, profile: store.activeProfile)
  }

  public func publishingPackage(for draft: ArticleDraft, store: WorkbenchStore) -> PublishPackage {
    publishPackageBuilder.build(draft: draft, profile: store.profile(for: draft))
  }

  public func localPublishPreview(for draft: ArticleDraft, store: WorkbenchStore) -> LocalPublishPreview {
    let package = publishingPackage(for: draft, store: store)
    return localPublishPreviewService.preview(package: package, profile: store.profile(for: draft))
  }

  public func remoteReviewDraft(for draft: ArticleDraft, store: WorkbenchStore) -> RemoteReviewDraft {
    remoteReviewDraftBuilder.build(package: publishingPackage(for: draft, store: store), profile: store.profile(for: draft))
  }

  public func draftComparisonContent(for draft: ArticleDraft, store: WorkbenchStore) -> DraftComparisonContent {
    let package = publishingPackage(for: draft, store: store)
    return DraftComparisonContent(
      repositoryPath: package.markdownPath,
      localContent: package.markdownFile?.content
    )
  }

  public func publishingAIPrompt(for draft: ArticleDraft, store: WorkbenchStore) -> String {
    let profile = store.profile(for: draft)
    let package = publishingPackage(for: draft, store: store)
    let issues = preflightIssues(for: draft, store: store) + remotePublishRiskService.issues(
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
    let issues = artifacts.preflightIssues + remotePublishRiskService.issues(
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
      lines.append(contentsOf: issues.map { "- [\($0.severity.displayName)] \($0.title)：\($0.message)" })
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
    return preflightService.run(
      draft: draft,
      allDrafts: allDrafts,
      profile: store.profile(for: draft),
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness
    )
  }

  func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool,
    allDrafts: [ArticleDraft],
    duplicateIndex: PreflightDuplicateIndex,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    if draft.isGeneralDraft {
      return [generalDraftPublishingIssue]
    }
    return preflightService.run(
      draft: draft,
      allDrafts: allDrafts,
      profile: store.profile(for: draft),
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness,
      duplicateIndex: duplicateIndex
    )
  }

  public func sitePreflightIssues(store: WorkbenchStore) -> [PreflightIssue] {
    let profile = store.activeProfile
    guard profile.purpose.requiresRepositoryReadiness else { return [] }
    if profile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      return [PreflightIssue(
        severity: .warning,
        title: CoreL10n.text("未选择本地仓库"),
        message: profile.purpose.repositoryRootMissingMessage,
        field: "repository"
      )]
    }
    return store.repositoryReport(for: profile)?.preflightIssues(
      requiringDeploymentReadiness: profile.purpose.requiresDeploymentReadiness
    ) ?? []
  }

  public func contentHealthSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    contentHealthReport(store: store).draftSummaries
  }

  public func contentHealthReport(store: WorkbenchStore) -> ContentHealthReport {
    contentHealthReportService.report(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      sitePreflightIssues: sitePreflightIssues(store: store),
      presentations: contentHealthPresentations(store: store)
    )
  }

  public func contentHealthReportAsync(store: WorkbenchStore) async throws -> ContentHealthReport {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let siteIssues = sitePreflightIssues(store: store)
    let presentations = contentHealthPresentations(store: store)
    return try await contentHealthReportService.reportAsync(
      drafts: drafts,
      profile: profile,
      sitePreflightIssues: siteIssues,
      presentations: presentations
    )
  }

  private func contentHealthPresentations(store: WorkbenchStore) -> [UUID: ContentHealthDraftPresentation] {
    Dictionary(uniqueKeysWithValues: store.visibleDrafts.map { draft in
      let display = store.privateContentDisplay(for: draft)
      let markdownPath = display.isMasked
        ? "内容已遮挡，打开文章或关闭私密遮挡后查看。"
        : store.profile(for: draft).markdownPath(for: draft)
      return (draft.id, ContentHealthDraftPresentation(title: display.title, markdownPath: markdownPath))
    })
  }

  public func publicRiskSummary(store: WorkbenchStore) -> PublicRiskSummary {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: profile.id) }
    let duplicateIndex = PreflightDuplicateIndex(drafts: allDrafts, profile: profile)
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
          store: store
        )
      )
    }
    return ContentHealthProjection.publicRiskSummary(from: summaries)
  }

  public func publicRiskSummary(for draft: ArticleDraft, store: WorkbenchStore) -> PublicRiskSummary {
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

  public func remoteRepositoryPublishPreview(for draft: ArticleDraft, store: WorkbenchStore) -> RemoteRepositoryPublishPreview {
    remoteRepositoryPublishPreview(
      package: store.publishingPackage(for: draft),
      profile: store.profile(for: draft),
      mode: preferredRemoteRepositoryPublishMode(for: store.profile(for: draft)),
      store: store
    )
  }

  public func remoteRepositoryPublishPreview(for plan: BatchPublishPlan, store: WorkbenchStore) -> RemoteRepositoryPublishPreview? {
    remotePublishPackage(for: plan).map {
      remoteRepositoryPublishPreview(
        package: $0,
        profile: store.activeProfile,
        mode: preferredRemoteRepositoryPublishMode(for: store.activeProfile),
        extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
        store: store
      )
    }
  }

  public func remotePublishPackage(for plan: BatchPublishPlan) -> PublishPackage? {
    let publishableItems = plan.remotePublishableItems
    guard let firstItem = publishableItems.first else { return nil }
    let files = deduplicatedBatchPublishFiles(publishableItems.flatMap(\.package.files))
    return PublishPackage(
      draftID: firstItem.draftID,
      title: "批量发布 \(publishableItems.count) 篇文章",
      draftSummary: nil,
      draftCoverAltText: nil,
      markdownPath: firstItem.markdownPath,
      files: files,
      commitMessage: "Publish: \(publishableItems.count) articles",
      reviewBranchName: "publish/batch-\(Self.batchPublishDateToken())",
      reviewTitle: "Publish \(publishableItems.count) articles",
      reviewChecklist: [
        "批量发布清单已确认",
        "图片路径和 alt/caption 已检查",
        "公开风险和私密内容已确认",
      ]
    )
  }

  public func remoteRepositoryPublishPreview(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    extraWarningIssues: [PreflightIssue] = [],
    localPreview: LocalPublishPreview? = nil,
    store: WorkbenchStore
  ) -> RemoteRepositoryPublishPreview {
    let preview = localPreview ?? localPublishPreviewService.preview(package: package, profile: profile)
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
    store: WorkbenchStore
  ) -> RemoteRepositoryPublishPreview {
    let repositoryName = profile.repositoryDisplayName
    let blockingIssues = blockingLocalPublishIssues(
      preview: localPreview,
      draftIssues: draftIssuesWithRepository
    )
    let remoteRiskAssessment = remotePublishRiskService.assessment(
      package: package,
      repositoryReport: store.repositoryReport(for: profile)
    )
    let remoteWarnings = remotePublishRiskService.issues(
      for: remoteRiskAssessment,
      includeUnknownState: true
    )
    let directConflictBlockingIssues = mode == .directCommit && remoteRiskAssessment.state == .conflict
      ? remoteWarnings
      : []
    let visibleRemoteWarnings = directConflictBlockingIssues.isEmpty ? remoteWarnings : []
    let accessCheck = store.activeRemoteRepositoryAccessCheck
    let tokenAccessBlockingIssues: [PreflightIssue] = store.repositoryTokenAvailability
      .accessFailureMessage
      .map { failureMessage in
        [PreflightIssue(
          severity: .error,
          title: CoreL10n.text("Token 状态读取失败"),
          message: CoreL10n.format(
            "仓库 Token 状态读取失败：%@",
            failureMessage
          ),
          field: "repositoryToken"
        )]
      } ?? []
    let permissionWarnings: [PreflightIssue] = store.repositoryTokenAvailability.hasToken && accessCheck == nil
      ? [PreflightIssue(
        severity: .warning,
        title: CoreL10n.text("Token 权限未检查"),
        message: CoreL10n.format(
          "当前 Token 尚未针对 %@ 完成写入权限检查，请先检查后再发布。",
          repositoryName
        ),
        field: "repositoryToken"
      )]
      : []
    return RemoteRepositoryPublishPreview(
      provider: profile.repositoryProvider,
      repositoryName: repositoryName,
      mode: mode,
      branchName: mode == .reviewRequest ? package.reviewBranchName : profile.branch,
      targetBranch: profile.branch,
      changedPaths: localPreview.changedFileDiffs.map(\.path),
      remoteConflictPaths: remoteRiskAssessment.conflictPaths,
      remoteRiskState: remoteRiskAssessment.state,
      hasToken: store.repositoryTokenAvailability.hasToken,
      tokenAccessFailureMessage: store.repositoryTokenAvailability.accessFailureMessage,
      accessCheck: accessCheck,
      blockingIssues: blockingIssues + tokenAccessBlockingIssues + directConflictBlockingIssues,
      warningIssues: visibleRemoteWarnings + permissionWarnings + extraWarningIssues
    )
  }

  public func batchRemoteRepositoryPublishWarningIssues(for plan: BatchPublishPlan) -> [PreflightIssue] {
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

  public func preferredRemoteRepositoryPublishMode(for profile: SiteProfile) -> RemoteRepositoryPublishMode {
    profile.repositoryPublishStrategy == .direct ? .directCommit : .reviewRequest
  }

  public func markDraftsAsPublishedIfDirectRemoteCommit(
    mode: RemoteRepositoryPublishMode,
    draftIDs: [UUID]
  ) {
    guard mode == .directCommit else { return }
    let now = Date()
    drafts = drafts.map { draft in
      guard draftIDs.contains(draft.id) else { return draft }
      var updatedDraft = draft
      updatedDraft.status = .published
      updatedDraft.updatedAt = now
      return updatedDraft
    }
  }

  func confirmLocalGitPublishLifecycle(
    package: PublishPackage,
    mode: LocalGitPublishMode
  ) {
    guard mode == .directCommit,
          let index = drafts.firstIndex(where: { $0.id == package.draftID }) else {
      return
    }
    let previousPath = drafts[index].repositoryPath?.normalizedRelativePath()
    let confirmedPath = package.markdownPath.normalizedRelativePath()
    drafts[index].repositoryPath = confirmedPath
    if previousPath != confirmedPath {
      drafts[index].repositorySHA = nil
    }
    drafts[index].repositoryImportFingerprint = drafts[index].repositoryContentFingerprint
    drafts[index].touch()
  }

  func confirmDirectRemotePublishLifecycle(
    packages: [PublishPackage],
    result: RemoteRepositoryPublishResult
  ) {
    guard result.mode == .directCommit else { return }
    let packagesByDraftID = Dictionary(uniqueKeysWithValues: packages.map { ($0.draftID, $0) })
    let now = Date()
    drafts = drafts.map { draft in
      guard let package = packagesByDraftID[draft.id] else { return draft }
      var updated = draft
      updated.repositoryPath = package.markdownPath.normalizedRelativePath()
      updated.repositorySHA = result.remoteVersion(for: package.markdownPath)
      updated.attachments = updated.attachments.map { attachment in
        guard let remoteVersion = result.remoteVersion(for: attachment.repositoryPath) else {
          return attachment
        }
        var confirmedAttachment = attachment
        confirmedAttachment.repositorySHA = remoteVersion
        return confirmedAttachment
      }
      updated.repositoryImportFingerprint = updated.repositoryContentFingerprint
      updated.updatedAt = now
      return updated
    }
  }

  public func partialRemoteRepositoryPublishFailure(from error: Error) -> RemoteRepositoryPublishResult? {
    guard case let RemoteRepositoryPublishError.partialPublish(provider, mode, branchName, targetBranch, changedPaths, commitSHA, _) = error else {
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
