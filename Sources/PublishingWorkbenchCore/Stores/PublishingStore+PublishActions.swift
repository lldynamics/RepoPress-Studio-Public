import Foundation

private struct SiteStarterOperationBaseline: Equatable {
  let profiles: [SiteProfile]
  let activeProfileID: UUID
  let drafts: [ArticleDraft]
  let selectedDraftID: UUID?
  let siteStarterResult: SiteStarterResult?
  let siteStarterImportResult: SiteStarterImportResult?
  let siteStarterPushResult: SiteStarterPushResult?

  @MainActor
  init(store: PublishingStore) {
    profiles = store.profiles
    activeProfileID = store.activeProfileID
    drafts = store.drafts
    selectedDraftID = store.selectedDraftID
    siteStarterResult = store.siteStarterResult
    siteStarterImportResult = store.siteStarterImportResult
    siteStarterPushResult = store.siteStarterPushResult
  }

  @MainActor
  func stillMatches(_ store: PublishingStore) -> Bool {
    self == SiteStarterOperationBaseline(store: store)
  }
}

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
    if let selectedDraftID,
       let selected = writingDrafts.first(where: { $0.id == selectedDraftID }) {
      return selected
    }
    return writingDrafts.first
  }

  /// Site-owned drafts for repository, publishing, maintenance and batch operations.
  public var visibleDrafts: [ArticleDraft] {
    drafts.filter { $0.belongs(toSiteProfileID: activeProfileID) }
  }

  /// Drafts shown by the Writing sidebar for its currently selected content scope.
  public var writingDrafts: [ArticleDraft] {
    switch draftListContentScope {
    case .currentSite:
      return visibleDrafts
    case .general:
      return drafts.filter(\.isGeneralDraft)
    }
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
    publishActionMessage = generalDraftPublishingIssue.message
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
    let writeBlockingIssues = blockingLocalPublishIssues(
      preview: preview,
      draftIssues: draftIssuesWithoutRepository
    )
    var commitBlockingIssues = blockingLocalPublishIssues(
      preview: preview,
      draftIssues: draftIssuesWithRepository
    )
    if profile.purpose.requiresRepositoryReadiness {
      if let repositoryReport = store.repositoryReport(for: profile) {
        if let missingGitIssue = repositoryReport.preflightIssues.first(where: { $0.title == "未发现 .git" }),
           !commitBlockingIssues.contains(where: { $0.title == missingGitIssue.title }) {
          commitBlockingIssues.append(missingGitIssue)
        }
      } else {
        commitBlockingIssues.append(
          PreflightIssue(
            severity: .error,
            title: "仓库尚未扫描",
            message: "请先刷新仓库状态，再执行提交或推送。",
            field: "repository"
          )
        )
      }
    }
    let remoteWarningIssues = remotePublishRiskService.issues(
      package: package,
      repositoryReport: store.repositoryReport(for: profile)
    )
    let warningIssues = (preview.issues + draftIssuesWithRepository + remoteWarningIssues)
      .filter { $0.severity == .warning }
    let changedFileCount = preview.changedFileDiffs.count
    let writeReadiness: LocalPublishActionReadiness = {
      if !writeBlockingIssues.isEmpty { return .blocked }
      if changedFileCount == 0 { return .unchanged }
      if !warningIssues.isEmpty { return .needsReview }
      return .ready
    }()
    let commitReadiness: LocalPublishActionReadiness = {
      if !commitBlockingIssues.isEmpty { return .blocked }
      if changedFileCount == 0 { return .unchanged }
      if !warningIssues.isEmpty { return .needsReview }
      return .ready
    }()
    return LocalPublishReadiness(
      writeReadiness: writeReadiness,
      commitReadiness: commitReadiness,
      changedFileCount: changedFileCount,
      fileCount: package.files.count,
      writeBlockingIssues: writeBlockingIssues,
      commitBlockingIssues: commitBlockingIssues,
      warningIssues: warningIssues
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
    (draftIssues + preview.issues).filter { $0.severity == .error }
  }

  public func blockedLocalPublishMessage(action: String, issues: [PreflightIssue]) -> String {
    let summary = issues.prefix(3).map { issue in
      issue.message.nilIfEmpty.map { "\(issue.title)（\($0)）" } ?? issue.title
    }.joined(separator: "、")
    return summary.isEmpty ? "已停止\(action)，请先处理发布检查错误。" : "已停止\(action)：\(summary)"
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
        title: "未选择本地仓库",
        message: profile.purpose.repositoryRootMissingMessage,
        field: "repository"
      )]
    }
    return store.repositoryReport(for: profile)?.preflightIssues(
      requiringDeploymentReadiness: profile.purpose.requiresDeploymentReadiness
    ) ?? []
  }

  public func contentHealthSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let allDrafts = store.drafts.filter { $0.belongs(toSiteProfileID: profile.id) }
    let duplicateIndex = PreflightDuplicateIndex(drafts: allDrafts, profile: profile)
    return drafts.map {
      let display = store.privateContentDisplay(for: $0)
      return DraftPreflightSummary(
        draftID: $0.id,
        draftTitle: display.title,
        markdownPath: display.isMasked
          ? "内容已遮挡，打开文章或关闭私密遮挡后查看。"
          : store.profile(for: $0).markdownPath(for: $0),
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
    return PublicRiskSummary(
      issues: drafts.flatMap {
        preflightIssues(
          for: $0,
          includeRepositoryReadiness: false,
          allDrafts: allDrafts,
          duplicateIndex: duplicateIndex,
          store: store
        )
      }
    )
  }

  public func publicRiskSummary(for draft: ArticleDraft, store: WorkbenchStore) -> PublicRiskSummary {
    PublicRiskSummary(issues: preflightIssues(for: draft, includeRepositoryReadiness: false, store: store))
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
    let permissionWarnings: [PreflightIssue] = store.repositoryTokenAvailability.hasToken && accessCheck == nil
      ? [PreflightIssue(
        severity: .warning,
        title: "Token 权限未检查",
        message: "当前 Token 尚未针对 \(repositoryName) 完成写入权限检查，请先检查后再发布。",
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
      accessCheck: accessCheck,
      blockingIssues: blockingIssues + directConflictBlockingIssues,
      warningIssues: visibleRemoteWarnings + permissionWarnings + extraWarningIssues
    )
  }

  public func batchRemoteRepositoryPublishWarningIssues(for plan: BatchPublishPlan) -> [PreflightIssue] {
    plan.items.flatMap { item in
      item.allIssues
        .filter { $0.severity == .warning }
        .map { issue in
          var titledIssue = issue
          titledIssue.title = "\(item.draftTitle)：\(issue.title)"
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

  @discardableResult
  public func importDraftsFromLocalRepository(store: WorkbenchStore) -> LocalContentImportMergeSummary {
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      publishActionMessage = "选择本地仓库后才能导入文章。"
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    store.flushDraftBodyEditorBuffers()
    return mergeImportedDrafts(localContentImportService.importDrafts(profile: store.activeProfile), store: store)
  }

  @discardableResult
  public func importDraftsFromLocalRepositoryAsync(store: WorkbenchStore) async -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      publishActionMessage = "选择本地仓库后才能导入文章。"
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }

    var draftBaselinesByRepositoryPath: [String: DraftOperationBaseline] = [:]
    for draft in drafts where draft.belongs(toSiteProfileID: profile.id) {
      guard let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
            let baseline = store.draftOperationBaseline(for: draft.id) else { continue }
      draftBaselinesByRepositoryPath[repositoryPath] = baseline
    }

    let operation = LocalRepositoryOperationContext(profile: profile)
    localImportOperationContext = operation
    publishActionMessage = "正在从本地仓库导入文章…"
    let result: LocalContentImportResult
    do {
      result = try await localContentImportService.importDraftsAsync(profile: profile)
    } catch is CancellationError {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        publishActionMessage = "已取消从本地仓库导入文章。"
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        publishActionMessage = "导入本地文章失败：\(error.localizedDescription)"
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard localImportOperationContext == operation else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard operation.stillMatches(store.activeProfile) else {
      localImportOperationContext = nil
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
    return mergeImportedDrafts(
      result,
      expectedBaselinesByRepositoryPath: draftBaselinesByRepositoryPath,
      store: store
    )
  }

  /// Discovers private repository articles that have never been added to the
  /// writing library. Existing drafts are intentionally left untouched so this
  /// launch-time backfill cannot overwrite local edits.
  @discardableResult
  public func importMissingPrivateDraftsFromLocalRepository(store: WorkbenchStore) async -> Int {
    let profile = store.activeProfile
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      return 0
    }

    let operation = LocalRepositoryOperationContext(profile: profile)
    let result: LocalContentImportResult
    do {
      result = try await localContentImportService.importDraftsAsync(profile: profile)
    } catch {
      return 0
    }
    guard operation.stillMatches(store.activeProfile) else {
      return 0
    }

    var existingPaths = Set(
      drafts.compactMap { draft -> String? in
        guard draft.belongs(toSiteProfileID: profile.id) else { return nil }
        return draft.repositoryPath?.normalizedRelativePath().nilIfEmpty
      }
    )
    let missingDrafts = result.importedDrafts.filter { draft in
      guard draft.belongs(toSiteProfileID: profile.id),
            draft.isPrivate,
            let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty else {
        return false
      }
      return existingPaths.insert(repositoryPath).inserted
    }
    guard !missingDrafts.isEmpty else {
      return 0
    }

    drafts.append(contentsOf: missingDrafts)
    if automaticallyRefreshPreflightOnEdit {
      store.schedulePreflightRefresh()
    }
    store.save()
    return missingDrafts.count
  }

  @discardableResult
  public func importDraftFromLocalRepository(
    repositoryPath: String,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let summary = mergeImportedDrafts(
      localContentImportService.importDraft(profile: store.activeProfile, repositoryPath: repositoryPath),
      store: store
    )
    let normalizedPath = repositoryPath.normalizedRelativePath()
    if let imported = drafts.first(where: { $0.belongs(toSiteProfileID: store.activeProfileID) && $0.repositoryPath == normalizedPath }) {
      selectedDraftID = imported.id
    }
    selectedSection = .writing
    store.save()
    return summary
  }

  public func makeContentMigrationPlan(sourceURL: URL, store: WorkbenchStore) async throws -> ContentMigrationPlan {
    let profile = store.activeProfile
    let plan = try await contentMigrationService.makePlanAsync(sourceURL: sourceURL, profile: profile)
    guard plan.profileID == store.activeProfileID,
          plan.profileConfiguration == ContentMigrationProfileConfiguration(profile: store.activeProfile) else {
      throw ContentMigrationError.profileChanged
    }
    store.flushDraftBodyEditorBuffers()
    return captureContentMigrationBaselines(in: plan, store: store)
  }

  private func captureContentMigrationBaselines(
    in plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) -> ContentMigrationPlan {
    var prepared = plan
    let pathCounts = Dictionary(
      grouping: plan.drafts,
      by: { $0.repositoryPath?.normalizedRelativePath() ?? "" }
    ).mapValues(\.count)
    let comparisonService = DraftVersionComparisonService()

    prepared.reviewItems = plan.drafts.map { importedDraft in
      let repositoryPath = importedDraft.repositoryPath?.normalizedRelativePath() ?? ""
      guard !repositoryPath.isEmpty,
            pathCounts[repositoryPath] == 1 else {
        return ContentMigrationDraftReviewItem(
          importedDraft: importedDraft,
          disposition: .conflict
        )
      }

      guard let existingDraft = drafts.first(where: {
        $0.belongs(toSiteProfileID: plan.profileID)
          && $0.repositoryPath?.normalizedRelativePath() == repositoryPath
      }), let operationBaseline = store.draftOperationBaseline(for: existingDraft.id) else {
        return ContentMigrationDraftReviewItem(
          importedDraft: importedDraft,
          disposition: .insert
        )
      }

      let comparison = comparisonService.compare(
        previous: existingDraft,
        current: importedDraft
      )
      return ContentMigrationDraftReviewItem(
        importedDraft: importedDraft,
        baseline: ContentMigrationDraftBaseline(
          draft: operationBaseline.draft,
          bodyRevision: operationBaseline.bodyRevision
        ),
        disposition: comparison.hasChanges ? .update : .unchanged,
        comparison: comparison
      )
    }
    prepared.drafts = prepared.reviewItems.map(\.importedDraft)
    return prepared
  }

  private func contentMigrationReviewItem(
    _ item: ContentMigrationDraftReviewItem,
    disposition: ContentMigrationDraftDisposition
  ) -> ContentMigrationDraftReviewItem {
    ContentMigrationDraftReviewItem(
      importedDraft: item.importedDraft,
      baseline: item.baseline,
      disposition: disposition,
      comparison: disposition == .update || disposition == .unchanged ? item.comparison : nil
    )
  }

  public func refreshContentMigrationPlanReview(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) -> ContentMigrationPlan {
    var refreshed = plan
    let pathCounts = Dictionary(
      grouping: plan.reviewItems,
      by: { $0.repositoryPath }
    ).mapValues(\.count)

    refreshed.reviewItems = plan.reviewItems.map { item in
      guard !item.repositoryPath.isEmpty,
            pathCounts[item.repositoryPath] == 1 else {
        return contentMigrationReviewItem(item, disposition: .conflict)
      }

      let currentDraft = drafts.first {
        $0.belongs(toSiteProfileID: plan.profileID)
          && $0.repositoryPath?.normalizedRelativePath() == item.repositoryPath
      }

      guard let baseline = item.baseline else {
        return currentDraft == nil
          ? contentMigrationReviewItem(item, disposition: .insert)
          : contentMigrationReviewItem(item, disposition: .conflict)
      }

      guard let currentDraft,
            currentDraft.id == baseline.draft.id,
            store.draftStillMatchesOperationBaseline(
              DraftOperationBaseline(
                draft: baseline.draft,
                bodyRevision: baseline.bodyRevision
              )
            ) else {
        return contentMigrationReviewItem(item, disposition: .conflict)
      }

      let comparison = DraftVersionComparisonService().compare(
        previous: currentDraft,
        current: item.importedDraft
      )
      return ContentMigrationDraftReviewItem(
        importedDraft: item.importedDraft,
        baseline: baseline,
        disposition: comparison.hasChanges ? .update : .unchanged,
        comparison: comparison
      )
    }
    refreshed.drafts = refreshed.reviewItems.map(\.importedDraft)
    return refreshed
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) throws -> LocalContentImportMergeSummary {
    let refreshed = refreshContentMigrationPlanReview(plan, store: store)
    let selectedDraftIDs = Set(
      refreshed.reviewItems
        .filter { $0.disposition.isSelectable }
        .map(\.id)
    )
    return try applyContentMigration(
      refreshed,
      selectedDraftIDs: selectedDraftIDs,
      store: store
    )
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    selectedDraftIDs: Set<UUID>,
    store: WorkbenchStore
  ) throws -> LocalContentImportMergeSummary {
    guard plan.profileID == store.activeProfileID,
          plan.profileConfiguration == ContentMigrationProfileConfiguration(profile: store.activeProfile) else {
      throw ContentMigrationError.profileChanged
    }
    store.flushDraftBodyEditorBuffers()
    let refreshed = refreshContentMigrationPlanReview(plan, store: store)
    let selectedItems = refreshed.reviewItems.filter { selectedDraftIDs.contains($0.id) }
    let conflicts = selectedItems
      .filter { $0.disposition == .conflict }
      .map { $0.repositoryPath.nilIfEmpty ?? $0.importedDraft.title }
    guard conflicts.isEmpty else {
      throw ContentMigrationError.draftsChanged(conflicts)
    }

    let importItems = selectedItems.filter { $0.disposition.isSelectable }
    guard !importItems.isEmpty else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }

    let expectedBaselines = Dictionary(
      uniqueKeysWithValues: importItems.compactMap { item -> (String, DraftOperationBaseline)? in
        guard let baseline = item.baseline else { return nil }
        return (
          item.repositoryPath,
          DraftOperationBaseline(draft: baseline.draft, bodyRevision: baseline.bodyRevision)
        )
      }
    )
    let selectedIDs = Set(importItems.map(\.id))
    let skippedPaths = refreshed.reviewItems
      .filter { !selectedIDs.contains($0.id) }
      .map(\.repositoryPath)
      .filter { !$0.isEmpty }
    let summary = mergeImportedDrafts(
      LocalContentImportResult(
        importedDrafts: importItems.map(\.importedDraft),
        skippedPaths: skippedPaths
      ),
      expectedBaselinesByRepositoryPath: expectedBaselines,
      store: store
    )
    if let firstImported = importItems.first?.importedDraft,
       let imported = drafts.first(where: { $0.siteProfileID == firstImported.siteProfileID && $0.repositoryPath == firstImported.repositoryPath }) {
      selectedDraftID = imported.id
    }
    selectedSection = .writing
    publishActionMessage = "已导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇；已生成 \(refreshed.imageMappings.count) 条图片路径映射和 \(refreshed.redirects.count) 条重定向候选。"
    store.save()
    return summary
  }

  @discardableResult
  public func importChangedArticleDraftsFromLocalRepository(store: WorkbenchStore) async -> LocalContentImportMergeSummary {
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      publishActionMessage = "选择本地仓库后才能导入文章。"
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    localImportOperationContext = operation
    let paths = (store.repositoryReport?.changedFiles ?? [])
      .filter { $0.kind != .deleted }
      .map(\.displayPath)
      .filter { path in
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      }
    store.flushDraftBodyEditorBuffers()
    var baselines: [String: DraftOperationBaseline] = [:]
    for path in paths {
      let normalizedPath = path.normalizedRelativePath()
      guard let draft = drafts.first(where: { $0.belongs(toSiteProfileID: profile.id) && $0.repositoryPath == normalizedPath }),
            let baseline = store.draftOperationBaseline(for: draft.id) else { continue }
      baselines[normalizedPath] = baseline
    }
    let result: LocalContentImportResult
    do {
      result = try await localContentImportService.importDraftsAsync(
        profile: profile,
        repositoryPaths: paths
      )
    } catch {
      if localImportOperationContext == operation {
        localImportOperationContext = nil
        publishActionMessage = error is CancellationError
          ? "已取消导入本地文章变更。"
          : "导入本地文章变更失败：\(error.localizedDescription)"
      }
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard localImportOperationContext == operation else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    guard operation.stillMatches(store.activeProfile) else {
      localImportOperationContext = nil
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
    let summary = mergeImportedDrafts(
      result,
      expectedBaselinesByRepositoryPath: baselines,
      store: store
    )
    selectedSection = .writing
    publishActionMessage = "已从文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。"
    store.save()
    return summary
  }

  @discardableResult
  public func importRemoteChangedArticleDraftsFromRepository(store: WorkbenchStore) -> LocalContentImportMergeSummary {
    let paths = (store.repositoryReport?.remoteChangedFiles ?? [])
      .map(\.displayPath)
    return importRemoteArticleDraftsFromRepository(repositoryPaths: paths, store: store)
  }

  @discardableResult
  public func importRemoteArticleDraftsFromRepository(
    repositoryPaths: [String],
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    var seenPaths = Set<String>()
    let paths = repositoryPaths
      .map { $0.normalizedRelativePath() }
      .filter { path in
        localContentImportService.isImportableArticleRepositoryPath(path, profile: profile)
      }
      .filter { seenPaths.insert($0).inserted }
    let result = remoteContentImportResult(paths: paths, profile: profile, store: store)
    let summary = mergeImportedDrafts(result, store: store)
    selectedSection = .writing
    if let firstPath = paths.first,
       let imported = drafts.first(where: { $0.belongs(toSiteProfileID: profile.id) && $0.repositoryPath == firstPath.normalizedRelativePath() }) {
      selectedDraftID = imported.id
    }
    publishActionMessage = "已从远端文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。"
    store.save()
    return summary
  }

  @discardableResult
  public func importRemoteDraftFromRepository(
    repositoryPath: String,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    store.flushDraftBodyEditorBuffers()
    let profile = store.activeProfile
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let result = remoteContentImportResult(paths: [normalizedPath], profile: profile, store: store)
    let summary = mergeImportedDrafts(result, store: store)
    if let imported = drafts.first(where: { $0.belongs(toSiteProfileID: profile.id) && $0.repositoryPath == normalizedPath }) {
      selectedDraftID = imported.id
      selectedSection = .writing
    }
    if let snapshot = store.repositoryStore.remoteFileSnapshot(profile: profile, repositoryPath: normalizedPath),
       summary.changedCount > 0 {
      publishActionMessage = "已从 \(snapshot.refName) 导入远端文章 \(normalizedPath)。"
    } else {
      publishActionMessage = "未能导入远端文章：\(normalizedPath)。"
    }
    store.save()
    return summary
  }

  /// Imports only remote article changes that can be proven safe. New paths are
  /// accepted, while an existing draft is replaced only when its repository
  /// content still matches the fingerprint recorded by the last import.
  @discardableResult
  public func autoImportRemoteArticleDrafts(
    remoteFiles: [RepositoryChangedFile],
    snapshots: [RepositoryFileSnapshot],
    locallyChangedPaths: Set<String>,
    store: WorkbenchStore
  ) -> RemoteArticleAutoImportSummary {
    let profile = store.activeProfile
    let snapshotsByPath = Dictionary(
      snapshots.map { ($0.repositoryPath.normalizedRelativePath(), $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    var summary = RemoteArticleAutoImportSummary()
    var seenPaths = Set<String>()
    var didMutateDrafts = false

    for file in remoteFiles {
      let path = file.displayPath.normalizedRelativePath()
      guard seenPaths.insert(path).inserted,
            localContentImportService.isImportableArticleRepositoryPath(path, profile: profile) else {
        continue
      }

      if file.kind == .deleted {
        summary.deletionPaths.append(path)
        continue
      }
      guard file.kind == .added || file.kind == .modified else {
        summary.conflictPaths.append(path)
        continue
      }
      guard !locallyChangedPaths.contains(path) else {
        summary.conflictPaths.append(path)
        continue
      }
      guard let snapshot = snapshotsByPath[path] else {
        summary.failedPaths.append(path)
        continue
      }

      let importResult = localContentImportService.importDraft(
        document: snapshot.content,
        repositoryPath: path,
        profile: profile,
        repositorySHA: snapshot.repositorySHA
      )
      guard var remoteDraft = importResult.importedDrafts.first else {
        summary.failedPaths.append(path)
        continue
      }
      let remoteFingerprint = remoteDraft.repositoryContentFingerprint
      remoteDraft.repositoryImportFingerprint = remoteFingerprint

      guard let existingIndex = drafts.firstIndex(where: {
        $0.belongs(toSiteProfileID: profile.id)
          && $0.repositoryPath?.normalizedRelativePath() == path
      }) else {
        drafts.append(remoteDraft)
        summary.insertedCount += 1
        summary.resolvedPaths.append(path)
        didMutateDrafts = true
        continue
      }

      let existing = drafts[existingIndex]
      let editorBuffer = store.draftBodyEditorBuffer(for: existing.id)
      guard !editorBuffer.isDirty else {
        summary.conflictPaths.append(path)
        continue
      }

      let existingFingerprint = existing.repositoryContentFingerprint
      let normalizedRemoteSHA = snapshot.repositorySHA?.trimmedForPublishing.nilIfEmpty
      if let normalizedRemoteSHA,
         existing.repositorySHA?.trimmedForPublishing == normalizedRemoteSHA {
        summary.unchangedCount += 1
        summary.resolvedPaths.append(path)
        continue
      }

      if existingFingerprint == remoteFingerprint {
        var confirmed = existing
        confirmed.repositorySHA = normalizedRemoteSHA
        confirmed.repositoryImportFingerprint = remoteFingerprint
        drafts[existingIndex] = confirmed
        summary.unchangedCount += 1
        summary.resolvedPaths.append(path)
        didMutateDrafts = didMutateDrafts || confirmed != existing
        continue
      }

      guard existing.repositoryImportFingerprint == existingFingerprint else {
        summary.conflictPaths.append(path)
        continue
      }

      remoteDraft.id = existing.id
      remoteDraft.createdAt = existing.createdAt
      recordAutomaticVersionIfNeeded(for: existing)
      remoteDraft.touch()
      drafts[existingIndex] = remoteDraft
      store.synchronizeDraftBodyEditorBuffer(with: remoteDraft)
      summary.updatedCount += 1
      summary.resolvedPaths.append(path)
      didMutateDrafts = true
    }

    if didMutateDrafts {
      if automaticallyRefreshPreflightOnEdit {
        store.schedulePreflightRefresh()
      }
      store.save()
    }
    return summary
  }

  private func remoteContentImportResult(
    paths: [String],
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> LocalContentImportResult {
    var importedDrafts: [ArticleDraft] = []
    var skippedPaths: [String] = []
    for path in paths {
      let normalizedPath = path.normalizedRelativePath()
      guard let snapshot = store.repositoryStore.remoteFileSnapshot(
        profile: profile,
        repositoryPath: normalizedPath
      ) else {
        skippedPaths.append(normalizedPath)
        continue
      }
      let imported = localContentImportService.importDraft(
        document: snapshot.content,
        repositoryPath: normalizedPath,
        profile: profile,
        repositorySHA: snapshot.repositorySHA
      )
      importedDrafts.append(contentsOf: imported.importedDrafts)
      skippedPaths.append(contentsOf: imported.skippedPaths)
    }
    return LocalContentImportResult(importedDrafts: importedDrafts, skippedPaths: skippedPaths)
  }

  @discardableResult
  public func createSiteFromStarter(
    _ request: SiteStarterRequest,
    store: WorkbenchStore
  ) async -> SiteStarterResult? {
    siteStarterOperationGeneration &+= 1
    let generation = siteStarterOperationGeneration
    let baseline = SiteStarterOperationBaseline(store: self)
    isSiteStarterOperationRunning = true
    publishActionMessage = "正在后台创建 Starter 站点…"
    defer {
      if siteStarterOperationGeneration == generation {
        isSiteStarterOperationRunning = false
      }
    }

    do {
      let result = try await siteStarterService.createSiteAsync(request: request)
      guard siteStarterOperationGeneration == generation else { return nil }
      guard baseline.stillMatches(self) else {
        publishActionMessage = "Starter 文件已生成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
        return nil
      }
      siteStarterResult = result
      siteStarterImportResult = nil
      siteStarterPushResult = nil
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      drafts.append(result.initialDraft)
      selectedDraftID = result.initialDraft.id
      publishActionMessage = "已创建 Starter 站点：\(result.profile.name)。"
      store.save()
      return result
    } catch {
      guard siteStarterOperationGeneration == generation else { return nil }
      publishActionMessage = "创建 Starter 站点失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func importExistingSiteFromStarter(
    _ request: SiteStarterImportRequest,
    store: WorkbenchStore
  ) async -> SiteStarterImportResult? {
    siteStarterOperationGeneration &+= 1
    let generation = siteStarterOperationGeneration
    let baseline = SiteStarterOperationBaseline(store: self)
    isSiteStarterOperationRunning = true
    publishActionMessage = "正在后台读取并导入已有站点…"
    defer {
      if siteStarterOperationGeneration == generation {
        isSiteStarterOperationRunning = false
      }
    }

    do {
      var result = try await siteStarterService.importExistingSiteAsync(request: request)
      let importedDrafts = try await localContentImportService.importDraftsAsync(profile: result.profile)
      guard siteStarterOperationGeneration == generation else { return nil }
      guard baseline.stillMatches(self) else {
        publishActionMessage = "站点读取完成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
        return nil
      }
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      let importSummary = mergeImportedDrafts(importedDrafts, store: store)
      result.importedDraftCount = importSummary.insertedCount
      result.updatedDraftCount = importSummary.updatedCount
      result.skippedPathCount = importSummary.skippedCount
      siteStarterImportResult = result
      siteStarterResult = nil
      siteStarterPushResult = nil
      selectedDraftID = store.visibleDrafts.first?.id
      publishActionMessage = "已导入已有站点：\(result.profile.name)。"
      store.save()
      return result
    } catch {
      guard siteStarterOperationGeneration == generation else { return nil }
      publishActionMessage = "导入已有站点失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func configureStarterSiteOrigin(store: WorkbenchStore) async -> Bool {
    guard var starterResult = siteStarterResult,
          starterResult.profile.id == store.activeProfileID else {
      publishActionMessage = "没有可配置远端的 Starter 生成结果，请先创建站点。"
      return false
    }
    let profile = store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return false
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在配置 Starter 的 origin remote…"

    do {
      let remoteURL = try await siteStarterService.configureGitHubOriginRemoteAsync(profile: profile)
      guard localRepositoryMutationContext == operation,
            operation.stillMatches(store.activeProfile) else {
        return false
      }
      starterResult.profile = profile
      starterResult.configuredRemoteURL = remoteURL
      siteStarterResult = starterResult
      publishActionMessage = "已配置 Starter 远端：\(profile.repositoryDisplayName)。"
      store.save()
      return true
    } catch {
      guard localRepositoryMutationContext == operation,
            operation.stillMatches(store.activeProfile) else {
        return false
      }
      publishActionMessage = "配置 Starter 远端失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func commitAndPushStarterSite(store: WorkbenchStore) async -> SiteStarterPushResult? {
    guard let starterResult = siteStarterResult else {
      publishActionMessage = "没有可提交的 Starter 生成结果，请先创建站点。"
      return nil
    }
    let profile = starterResult.profile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return nil
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在提交并推送 Starter…"
    do {
      let result = try await siteStarterService.commitAndPushStarterSiteAsync(
        profile: profile,
        createdFilePaths: starterResult.createdFilePaths
      )
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else {
        return nil
      }
      siteStarterPushResult = result
      publishActionMessage = "Starter 已提交并推送：\(result.commitSHA.prefix(8))。"
      store.save()
      return result
    } catch {
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else {
        return nil
      }
      publishActionMessage = "Starter 提交推送失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func generalDraftLibraryReport() -> GeneralDraftLibraryReport {
    generalDraftLibraryService.report(
      drafts: drafts,
      profiles: profiles
    )
  }

  public func generalDraftSourceFieldDiffs(for draft: ArticleDraft) -> [String] {
    guard let source = draft.reusedFromSourceSnapshot else { return [] }
    return generalDraftLibraryService.sourceFieldDiffs(from: source, to: draft)
  }

  public func localSitePreviewPlan(for draft: ArticleDraft, store: WorkbenchStore) -> LocalSitePreviewPlan? {
    localSitePreviewService.plan(profile: store.profile(for: draft))
  }

  public func localSitePreviewURL(for draft: ArticleDraft, store: WorkbenchStore) -> URL? {
    localSitePreviewService.previewURL(for: draft, profile: store.profile(for: draft))
  }

  public func refreshLocalSitePreviewPlan(for profile: SiteProfile) {
    let updatedPlan = localSitePreviewService.plan(profile: profile)
    guard updatedPlan != localSitePreviewPlan else { return }

    if localSitePreviewRuntimeStatus.isRunning {
      requestLocalSitePreviewStop(message: "站点预览配置已变更，正在停止原来的本地预览。")
    }

    localSitePreviewPlan = updatedPlan
  }

  public func stopLocalSitePreview() {
    requestLocalSitePreviewStop(message: "正在停止本地预览。")
  }

  public func stopLocalSitePreviewImmediately() {
    localSitePreviewGeneration &+= 1
    localSitePreviewProcessService.stop()
    localSitePreviewStopTask = nil
    localSitePreviewStopOperationID = nil
    localSitePreviewRuntimeStatus = .stopped
  }

  public func refreshLocalSitePreviewRuntimeStatus() {
    localSitePreviewRuntimeStatus = localSitePreviewProcessService.status
  }

  public func verifyLocalSitePreviewReachability() async {
    guard let previewURL = localSitePreviewRuntimeStatus.previewURL ?? localSitePreviewPlan?.previewURL else {
      return
    }

    guard localSitePreviewRuntimeStatus.isRunning else {
      refreshLocalSitePreviewRuntimeStatus()
      return
    }

    var request = URLRequest(url: previewURL)
    request.timeoutInterval = 1.5
    request.cachePolicy = .reloadIgnoringLocalCacheData

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let responseCode = (response as? HTTPURLResponse)?.statusCode
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: true,
        isReachable: true,
        processIdentifier: localSitePreviewRuntimeStatus.processIdentifier,
        previewURL: previewURL,
        message: responseCode.map { "本地预览可访问（HTTP \($0)）。" } ?? "本地预览端口可访问。",
        startedAt: localSitePreviewRuntimeStatus.startedAt,
        recentLogLines: localSitePreviewProcessService.status.recentLogLines
      )
    } catch {
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: localSitePreviewProcessService.status.isRunning,
        isReachable: false,
        processIdentifier: localSitePreviewProcessService.status.processIdentifier,
        previewURL: previewURL,
        message: "尚未检测到本地预览端口：\(error.localizedDescription)",
        startedAt: localSitePreviewProcessService.status.startedAt,
        recentLogLines: localSitePreviewProcessService.status.recentLogLines
      )
    }
  }

  public func startLocalSitePreview() {
    guard let plan = localSitePreviewPlan else {
      localSitePreviewRuntimeStatus = .stopped
      publishActionMessage = "请先为当前站点选择本地仓库，才能启动本地预览。"
      return
    }

    localSitePreviewGeneration &+= 1
    let generation = localSitePreviewGeneration
    if let stopTask = localSitePreviewStopTask {
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: plan.previewURL,
        message: "正在等待原来的本地预览停止。"
      )
      publishActionMessage = localSitePreviewRuntimeStatus.message
      Task { [weak self] in
        await stopTask.value
        guard let self, self.localSitePreviewGeneration == generation else { return }
        self.startLocalSitePreview(plan: plan, generation: generation)
      }
      return
    }

    startLocalSitePreview(plan: plan, generation: generation)
  }

  private func startLocalSitePreview(plan: LocalSitePreviewPlan, generation: UInt64) {
    do {
      localSitePreviewRuntimeStatus = try localSitePreviewProcessService.start(plan: plan)
      publishActionMessage = localSitePreviewRuntimeStatus.message
      Task { [weak self] in
        for _ in 0 ..< 5 {
          try? await Task.sleep(for: .seconds(1))
          guard let self,
                self.localSitePreviewGeneration == generation,
                self.localSitePreviewRuntimeStatus.isRunning else { return }
          await self.verifyLocalSitePreviewReachability()
          if self.localSitePreviewRuntimeStatus.isReachable { return }
        }
      }
    } catch {
      localSitePreviewRuntimeStatus = .stopped
      publishActionMessage = "本地预览启动失败：\(error.localizedDescription)"
    }
  }

  private func requestLocalSitePreviewStop(message: String) {
    guard localSitePreviewStopTask == nil else {
      publishActionMessage = message
      return
    }

    localSitePreviewGeneration &+= 1
    let generation = localSitePreviewGeneration
    let operationID = UUID()
    let previewURL = localSitePreviewRuntimeStatus.previewURL ?? localSitePreviewPlan?.previewURL
    localSitePreviewStopOperationID = operationID
    localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
      isRunning: false,
      previewURL: previewURL,
      message: "正在停止本地预览。"
    )
    publishActionMessage = message

    let processService = localSitePreviewProcessService
    localSitePreviewStopTask = Task { [weak self] in
      await processService.stopAsync()
      guard let self, self.localSitePreviewStopOperationID == operationID else { return }
      self.localSitePreviewStopTask = nil
      self.localSitePreviewStopOperationID = nil
      if self.localSitePreviewGeneration == generation {
        self.localSitePreviewRuntimeStatus = .stopped
      }
    }
  }

  @discardableResult
  public func copyDraft(
    _ draftID: UUID,
    toProfileID targetProfileID: UUID,
    store: WorkbenchStore
  ) -> ArticleDraft? {
    let plan = draftOwnershipTransferPlan(
      draftIDs: [draftID],
      operation: .copyToSite,
      targetProfileID: targetProfileID
    )
    guard let result = applyDraftOwnershipTransfer(plan, store: store),
          let copiedID = result.affectedDraftIDs.first else {
      return nil
    }
    return drafts.first(where: { $0.id == copiedID })
  }

  private func mergeImportedDrafts(
    _ result: LocalContentImportResult,
    expectedBaselinesByRepositoryPath: [String: DraftOperationBaseline]? = nil,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    var insertedCount = 0
    var updatedCount = 0
    var conflictCount = 0
    for imported in result.importedDrafts {
      let repositoryPath = imported.repositoryPath?.normalizedRelativePath() ?? ""
      if let index = drafts.firstIndex(where: { $0.siteProfileID == imported.siteProfileID && $0.repositoryPath == imported.repositoryPath }) {
        if let expectedBaselinesByRepositoryPath {
          guard let baseline = expectedBaselinesByRepositoryPath[repositoryPath],
                baseline.draft.id == drafts[index].id,
                store.draftStillMatchesOperationBaseline(baseline) else {
            conflictCount += 1
            continue
          }
        }
        var updated = imported
        updated.id = drafts[index].id
        updated.createdAt = drafts[index].createdAt
        if drafts[index] != updated {
          recordAutomaticVersionIfNeeded(for: drafts[index])
          updated.touch()
          drafts[index] = updated
          updatedCount += 1
        }
      } else {
        if let expectedBaselinesByRepositoryPath,
           expectedBaselinesByRepositoryPath[repositoryPath] != nil {
          conflictCount += 1
          continue
        }
        drafts.append(imported)
        insertedCount += 1
      }
    }
    let skippedCount = result.skippedPaths.count + conflictCount
    let summary = LocalContentImportMergeSummary(
      insertedCount: insertedCount,
      updatedCount: updatedCount,
      skippedCount: skippedCount
    )
    if insertedCount + updatedCount > 0, automaticallyRefreshPreflightOnEdit {
      store.schedulePreflightRefresh()
    }
    if conflictCount > 0 {
      publishActionMessage = "导入完成：新增 \(insertedCount) 篇、更新 \(updatedCount) 篇；\(conflictCount) 篇在导入期间被本地修改，已保留本地版本。"
    } else {
      publishActionMessage = "导入完成：新增 \(insertedCount) 篇、更新 \(updatedCount) 篇、跳过 \(result.skippedPaths.count) 个文件。"
    }
    store.save()
    return summary
  }
}
