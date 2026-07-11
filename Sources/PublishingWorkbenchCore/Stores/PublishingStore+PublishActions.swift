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
    if let selectedDraftID,
       let selected = drafts.first(where: { $0.id == selectedDraftID && $0.siteProfileID == activeProfileID }) {
      return selected
    }
    return visibleDrafts.first
  }

  public var visibleDrafts: [ArticleDraft] {
    drafts.filter { $0.siteProfileID == activeProfileID }
  }

  public func profile(for draft: ArticleDraft) -> SiteProfile {
    profiles.first { $0.id == draft.siteProfileID } ?? activeProfile
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
    profile: SiteProfile,
    preview: LocalPublishPreview,
    includeRepositoryReadiness: Bool,
    store: WorkbenchStore
  ) -> [PreflightIssue] {
    let draftIssues = store.drafts.first(where: { $0.id == package.draftID })
      .map { store.preflightIssues(for: $0, includeRepositoryReadiness: includeRepositoryReadiness) }
      ?? []
    return (draftIssues + preview.issues).filter { $0.severity == .error }
  }

  public func makeLocalPublishReadiness(
    package: PublishPackage,
    profile: SiteProfile,
    preview: LocalPublishPreview,
    store: WorkbenchStore
  ) -> LocalPublishReadiness {
    let writeBlockingIssues = blockingLocalPublishIssues(
      package: package,
      profile: profile,
      preview: preview,
      includeRepositoryReadiness: false,
      store: store
    )
    var commitBlockingIssues = blockingLocalPublishIssues(
      package: package,
      profile: profile,
      preview: preview,
      includeRepositoryReadiness: true,
      store: store
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
    let warningIssues = (preview.issues
      + (store.drafts.first(where: { $0.id == package.draftID }).map { store.preflightIssues(for: $0) } ?? [])
      + remoteWarningIssues)
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
    let package = publishingPackage(for: selectedDraft, store: store)
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    publishPackage = package
    localPublishPreview = preview
    localPublishReadiness = makeLocalPublishReadiness(package: package, profile: profile, preview: preview, store: store)
    remotePublishPreviewSnapshot = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: preferredRemoteRepositoryPublishMode(for: profile),
      localPreview: preview,
      store: store
    )
    remoteReviewDraft = remoteReviewDraftBuilder.build(package: package, profile: profile)
  }

  public func refreshBatchPublishPlan(store: WorkbenchStore) {
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
      "本地 diff：\(localPreview.changedFileDiffs.count) 个待写入变化。",
      "本地预览：\(sitePreview?.command ?? "尚未配置本地预览命令。")",
      "图片检查：\(imageReport.items.count) 张，缺 alt \(imageReport.missingAltTextCount) 张，缺源图 \(imageReport.missingSourceCount) 张。",
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
    preflightService.run(
      draft: draft,
      allDrafts: store.drafts.filter { $0.siteProfileID == draft.siteProfileID },
      profile: store.profile(for: draft),
      repositoryReport: store.repositoryReport(for: draft),
      includeRepositoryReadiness: includeRepositoryReadiness
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
    store.visibleDrafts.map {
      let display = store.privateContentDisplay(for: $0)
      return DraftPreflightSummary(
        draftID: $0.id,
        draftTitle: display.title,
        markdownPath: display.isMasked
          ? "内容已遮挡，打开文章或关闭私密遮挡后查看。"
          : store.profile(for: $0).markdownPath(for: $0),
        issues: preflightIssues(for: $0, includeRepositoryReadiness: false, store: store)
      )
    }
  }

  public func contentHealthReport(store: WorkbenchStore) -> ContentHealthReport {
    ContentHealthReportService().report(
      drafts: store.visibleDrafts,
      profile: store.activeProfile,
      sitePreflightIssues: sitePreflightIssues(store: store),
      presentations: contentHealthPresentations(store: store)
    )
  }

  public func contentHealthReportAsync(store: WorkbenchStore) async -> ContentHealthReport {
    let drafts = store.visibleDrafts
    let profile = store.activeProfile
    let siteIssues = sitePreflightIssues(store: store)
    let presentations = contentHealthPresentations(store: store)
    return await ContentHealthReportService().reportAsync(
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
    PublicRiskSummary(
      issues: store.visibleDrafts.flatMap {
        preflightIssues(for: $0, includeRepositoryReadiness: false, store: store)
      }
    )
  }

  public func publicRiskSummary(for draft: ArticleDraft, store: WorkbenchStore) -> PublicRiskSummary {
    PublicRiskSummary(issues: preflightIssues(for: draft, includeRepositoryReadiness: false, store: store))
  }

  public func publicRiskDraftSummaries(store: WorkbenchStore) -> [DraftPreflightSummary] {
    store.visibleDrafts.map {
      DraftPreflightSummary(
        draftID: $0.id,
        draftTitle: $0.title,
        markdownPath: store.profile(for: $0).markdownPath(for: $0),
        issues: preflightIssues(for: $0, includeRepositoryReadiness: false, store: store)
      )
    }
  }

  public func aiFixQueueItems(store: WorkbenchStore) -> [AIPublishingFixQueueItem] {
    AIPublishingFixQueueService().items(
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
    remotePublishPackage(for: plan, profile: store.activeProfile).map {
      remoteRepositoryPublishPreview(
        package: $0,
        profile: store.activeProfile,
        mode: preferredRemoteRepositoryPublishMode(for: store.activeProfile),
        extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
        store: store
      )
    }
  }

  public func remotePublishPackage(for plan: BatchPublishPlan, profile: SiteProfile) -> PublishPackage? {
    let publishableItems = plan.remotePublishableItems
    guard let firstItem = publishableItems.first else { return nil }
    let files = publishableItems.flatMap(\.package.files)
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
    let repositoryName = profile.repositoryDisplayName
    let preview = localPreview ?? localPublishPreviewService.preview(package: package, profile: profile)
    let blockingIssues = blockingLocalPublishIssues(
      package: package,
      profile: profile,
      preview: preview,
      includeRepositoryReadiness: true,
      store: store
    )
    let remoteConflictPaths = remotePublishRiskService.remoteConflictPaths(
      package: package,
      repositoryReport: store.repositoryReport(for: profile)
    )
    let remoteWarnings = remotePublishRiskService.issues(
      package: package,
      repositoryReport: store.repositoryReport(for: profile)
    )
    let directConflictBlockingIssues = mode == .directCommit ? remoteWarnings : []
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
      changedPaths: preview.changedFileDiffs.map(\.path),
      remoteConflictPaths: remoteConflictPaths,
      hasToken: store.repositoryTokenAvailability.hasToken,
      accessCheck: accessCheck,
      blockingIssues: blockingIssues + directConflictBlockingIssues,
      warningIssues: remoteWarnings + permissionWarnings + extraWarningIssues
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
    for draft in drafts where draft.siteProfileID == profile.id {
      guard let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
            let baseline = store.draftOperationBaseline(for: draft.id) else { continue }
      draftBaselinesByRepositoryPath[repositoryPath] = baseline
    }

    let operation = LocalRepositoryOperationContext(profile: profile)
    localImportOperationContext = operation
    publishActionMessage = "正在从本地仓库导入文章…"
    let result = await Task.detached(priority: .userInitiated) {
      LocalContentImportService().importDrafts(profile: profile)
    }.value
    guard localImportOperationContext == operation, operation.stillMatches(store.activeProfile) else {
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    localImportOperationContext = nil
    return mergeImportedDrafts(
      result,
      expectedBaselinesByRepositoryPath: draftBaselinesByRepositoryPath,
      store: store
    )
  }

  @discardableResult
  public func importDraftFromLocalRepository(
    repositoryPath: String,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    let summary = mergeImportedDrafts(
      localContentImportService.importDraft(profile: store.activeProfile, repositoryPath: repositoryPath),
      store: store
    )
    let normalizedPath = repositoryPath.normalizedRelativePath()
    if let imported = drafts.first(where: { $0.siteProfileID == store.activeProfileID && $0.repositoryPath == normalizedPath }) {
      selectedDraftID = imported.id
    }
    selectedSection = .writing
    store.save()
    return summary
  }

  public func makeContentMigrationPlan(sourceURL: URL, store: WorkbenchStore) async throws -> ContentMigrationPlan {
    let profile = store.activeProfile
    return try await contentMigrationService.makePlanAsync(sourceURL: sourceURL, profile: profile)
  }

  @discardableResult
  public func applyContentMigration(
    _ plan: ContentMigrationPlan,
    store: WorkbenchStore
  ) throws -> LocalContentImportMergeSummary {
    guard plan.profileID == store.activeProfileID else {
      throw ContentMigrationError.profileChanged
    }
    let summary = mergeImportedDrafts(
      LocalContentImportResult(importedDrafts: plan.drafts, skippedPaths: []),
      store: store
    )
    if let firstImported = plan.drafts.first,
       let imported = drafts.first(where: { $0.siteProfileID == firstImported.siteProfileID && $0.repositoryPath == firstImported.repositoryPath }) {
      selectedDraftID = imported.id
    }
    selectedSection = .writing
    publishActionMessage = "已导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇；已生成 \(plan.imageMappings.count) 条图片路径映射和 \(plan.redirects.count) 条重定向候选。"
    store.save()
    return summary
  }

  @discardableResult
  public func importChangedArticleDraftsFromLocalRepository(store: WorkbenchStore) -> LocalContentImportMergeSummary {
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      publishActionMessage = "选择本地仓库后才能导入文章。"
      return LocalContentImportMergeSummary(insertedCount: 0, updatedCount: 0, skippedCount: 0)
    }
    let profile = store.activeProfile
    let contentRoot = profile.contentRoot.normalizedRelativePath() + "/"
    let paths = (store.repositoryReport?.changedFiles ?? [])
      .filter { $0.kind != .deleted }
      .map(\.displayPath)
      .filter { path in
        path.normalizedRelativePath().hasPrefix(contentRoot)
          && ["md", "markdown", "mdx"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
      }
    var importedDrafts: [ArticleDraft] = []
    var skippedPaths: [String] = []
    for path in paths {
      let result = localContentImportService.importDraft(profile: profile, repositoryPath: path)
      importedDrafts.append(contentsOf: result.importedDrafts)
      skippedPaths.append(contentsOf: result.skippedPaths)
    }
    let summary = mergeImportedDrafts(
      LocalContentImportResult(importedDrafts: importedDrafts, skippedPaths: skippedPaths),
      store: store
    )
    selectedSection = .writing
    publishActionMessage = "已从文章变更导入 \(summary.insertedCount) 篇、更新 \(summary.updatedCount) 篇。"
    store.save()
    return summary
  }

  @discardableResult
  public func importRemoteChangedArticleDraftsFromRepository(store: WorkbenchStore) -> LocalContentImportMergeSummary {
    let profile = store.activeProfile
    let contentRoot = profile.contentRoot.normalizedRelativePath() + "/"
    let paths = (store.repositoryReport?.remoteChangedFiles ?? [])
      .map(\.displayPath)
      .filter { path in
        path.normalizedRelativePath().hasPrefix(contentRoot)
          && ["md", "markdown", "mdx"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
      }
    let result = remoteContentImportResult(paths: paths, profile: profile, store: store)
    let summary = mergeImportedDrafts(result, store: store)
    selectedSection = .writing
    if let firstPath = paths.first,
       let imported = drafts.first(where: { $0.siteProfileID == profile.id && $0.repositoryPath == firstPath.normalizedRelativePath() }) {
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
    let profile = store.activeProfile
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let result = remoteContentImportResult(paths: [normalizedPath], profile: profile, store: store)
    let summary = mergeImportedDrafts(result, store: store)
    if let imported = drafts.first(where: { $0.siteProfileID == profile.id && $0.repositoryPath == normalizedPath }) {
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
  ) -> SiteStarterResult? {
    do {
      let result = try siteStarterService.createSite(request: request)
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
      publishActionMessage = "创建 Starter 站点失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func importExistingSiteFromStarter(
    _ request: SiteStarterImportRequest,
    store: WorkbenchStore
  ) -> SiteStarterImportResult? {
    do {
      var result = try siteStarterService.importExistingSite(request: request)
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      let importSummary = mergeImportedDrafts(localContentImportService.importDrafts(profile: result.profile), store: store)
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
      publishActionMessage = "导入已有站点失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func commitAndPushStarterSite(store: WorkbenchStore) async -> SiteStarterPushResult? {
    let profile = siteStarterResult?.profile ?? store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return nil
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在提交并推送 Starter…"
    do {
      let result = try await siteStarterService.commitAndPushStarterSiteAsync(profile: profile)
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

  public func generalDraftLibraryReport(store: WorkbenchStore) -> GeneralDraftLibraryReport {
    generalDraftLibraryService.report(
      drafts: drafts,
      profiles: profiles,
      masksPrivateContent: store.privacySettings.masksPrivateContent
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

  public func generalDraftLibraryPackagePlan() -> GeneralDraftLibraryPackagePlan {
    let profile = profiles.first { $0.purpose == .generalDraftBackup }
    return generalDraftLibraryService.packagePlan(drafts: drafts, profile: profile)
  }

  public func generalDraftBackupPlan() -> GeneralDraftBackupPlan {
    let profile = profiles.first { $0.purpose == .generalDraftBackup }
    return generalDraftLibraryService.backupPlan(drafts: drafts, profile: profile)
  }

  @discardableResult
  public func writeGeneralDraftBackupToRepository(store: WorkbenchStore) -> GeneralDraftBackupWriteResult? {
    do {
      let result = try generalDraftLibraryService.writeBackup(generalDraftBackupPlan())
      latestGeneralDraftBackupWriteResult = result
      publishActionMessage = result.deletedStalePaths.isEmpty
        ? result.statusMessage
        : "\(result.statusMessage) 已清理：\(result.deletedStalePaths.joined(separator: "、"))"
      store.save()
      return result
    } catch {
      publishActionMessage = "素材备份写入失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func ensureGeneralDraftProfile(store: WorkbenchStore) -> SiteProfile {
    if let profile = profiles.first(where: { $0.purpose == .generalDraftBackup }) {
      activeProfileID = profile.id
      selectedSection = .generalDrafts
      return profile
    }
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.name = "素材库"
    profile.purpose = .generalDraftBackup
    profile.contentRoot = "general-drafts"
    profile.markdownPathPattern = "general-drafts/{slug}.md"
    profiles.append(profile)
    activeProfileID = profile.id
    selectedSection = .generalDrafts
    store.save()
    return profile
  }

  @discardableResult
  public func createGeneralDraft(store: WorkbenchStore) -> ArticleDraft {
    let profile = ensureGeneralDraftProfile(store: store)
    var draft = ArticleDraft.empty(profile: profile)
    draft.title = "未命名素材"
    draft.repositoryPath = profile.markdownPath(for: draft)
    drafts.insert(draft, at: 0)
    selectedDraftID = draft.id
    store.save()
    return draft
  }

  @discardableResult
  public func copyDraftToGeneralLibrary(_ draftID: UUID, store: WorkbenchStore) -> ArticleDraft? {
    guard let source = drafts.first(where: { $0.id == draftID }) else { return nil }
    if profiles.first(where: { $0.id == source.siteProfileID })?.purpose == .generalDraftBackup {
      activeProfileID = source.siteProfileID
      selectedDraftID = source.id
      selectedSection = .generalDrafts
      publishActionMessage = "这篇已经在素材库中。"
      return source
    }
    let profile = ensureGeneralDraftProfile(store: store)
    var copied = source
    copied.id = UUID()
    copied.siteProfileID = profile.id
    copied.status = .draft
    copied.draft = true
    copied.repositorySHA = nil
    copied.repositoryPath = nil
    copied.createdAt = Date()
    copied.updatedAt = copied.createdAt
    drafts.insert(copied, at: 0)
    selectedDraftID = copied.id
    selectedSection = .generalDrafts
    publishActionMessage = "已收进素材库：\(copied.title)"
    store.save()
    return copied
  }

  @discardableResult
  public func copyDraftToActiveProfile(_ draftID: UUID, store: WorkbenchStore) -> ArticleDraft? {
    guard let source = drafts.first(where: { $0.id == draftID }) else { return nil }
    let sourceProfile = profiles.first { $0.id == source.siteProfileID }
    let targetProfile = activeProfile
    var copied = source
    copied.id = UUID()
    copied.siteProfileID = activeProfileID
    copied.status = .draft
    copied.draft = true
    copied.repositoryPath = nil
    copied.repositorySHA = nil
    copied.reusedFromSourceSnapshot = GeneralDraftReuseSourceSnapshot.make(
      from: source,
      sourceProfileName: sourceProfile?.name ?? "未知 Profile"
    )
    copied.createdAt = Date()
    copied.updatedAt = copied.createdAt
    drafts.insert(copied, at: 0)
    selectedDraftID = copied.id
    selectedSection = .writing
    latestGeneralDraftReusePlan = generalDraftLibraryService.reusePlan(
      sourceDraft: source,
      copiedDraft: copied,
      sourceProfile: sourceProfile,
      targetProfile: targetProfile
    )
    publishActionMessage = latestGeneralDraftReusePlan.map {
      "已复制到 \(targetProfile.name)：\($0.targetMarkdownPath)"
    }
    store.save()
    return copied
  }

  @discardableResult
  public func importGeneralDraftLibraryPackage(
    from packageText: String,
    store: WorkbenchStore
  ) -> LocalContentImportMergeSummary {
    let profile = ensureGeneralDraftProfile(store: store)
    let entries = generalDraftLibraryService.parsePackageEntries(from: packageText)
    var insertedCount = 0
    var updatedCount = 0
    var skippedCount = 0

    for entry in entries {
      var incoming = generalDraftLibraryService.draft(from: entry, profile: profile)
      incoming.repositoryPath = entry.relativePath
      if let index = drafts.firstIndex(where: { $0.siteProfileID == profile.id && $0.repositoryPath == entry.relativePath }) {
        incoming.id = drafts[index].id
        incoming.createdAt = drafts[index].createdAt
        drafts[index] = incoming
        updatedCount += 1
      } else {
        drafts.append(incoming)
        insertedCount += 1
      }
    }

    if entries.isEmpty {
      skippedCount = 1
      publishActionMessage = "没有找到可导入的素材包。"
    } else {
      publishActionMessage = "已从素材包导入 \(insertedCount) 篇、更新 \(updatedCount) 篇。"
    }
    store.save()
    return LocalContentImportMergeSummary(insertedCount: insertedCount, updatedCount: updatedCount, skippedCount: skippedCount)
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
        store.updateDraft(updated)
        updatedCount += 1
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
    if conflictCount > 0 {
      publishActionMessage = "导入完成：新增 \(insertedCount) 篇、更新 \(updatedCount) 篇；\(conflictCount) 篇在导入期间被本地修改，已保留本地版本。"
    } else {
      publishActionMessage = "导入完成：新增 \(insertedCount) 篇、更新 \(updatedCount) 篇、跳过 \(result.skippedPaths.count) 个文件。"
    }
    store.save()
    return summary
  }

  private static func batchPublishDateToken() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  public func writeSelectedDraftToLocalRepository(store: WorkbenchStore) async {
    if let draftID = publishPackage?.draftID {
      _ = store.focusDraft(draftID, section: .sync)
    }

    guard let package = publishPackage else {
      publishActionMessage = "没有可写入的发布包。"
      return
    }

    let profile = store.profile(for: package)
    let preview = localPublishPreviewService.preview(package: package, profile: profile)
    localPublishPreview = preview
    let blockingIssues = blockingLocalPublishIssues(
      package: package,
      profile: profile,
      preview: preview,
      includeRepositoryReadiness: false,
      store: store
    )
    localPublishReadiness = makeLocalPublishReadiness(package: package, profile: profile, preview: preview, store: store)
    guard blockingIssues.isEmpty else {
      publishActionMessage = blockedLocalPublishMessage(action: "写入", issues: blockingIssues)
      return
    }

    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在后台写入本地仓库…"

    do {
      let writtenPaths = try await localPublishPreviewService.writeAsync(
        package: package,
        profile: profile
      )
      releaseRecords.insert(
        .localWrite(package: package, profile: profile, writtenPaths: writtenPaths),
        at: 0
      )
      let stillCurrent = localRepositoryMutationContext == operation
        && store.profiles.first(where: { $0.id == profile.id }).map(operation.stillMatches) == true
        && store.activeProfileID == profile.id
      if stillCurrent {
        publishActionMessage = "已写入 \(writtenPaths.count) 个文件到本地仓库。"
        store.requestRepositoryScan()
      } else {
        publishActionMessage = "原站点已写入 \(writtenPaths.count) 个文件；当前站点已变化，未刷新当前仓库状态。"
      }
      store.save()
    } catch {
      let prefix = store.activeProfileID == profile.id ? "写入失败" : "原站点写入失败"
      publishActionMessage = "\(prefix)：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func writeBatchReadyDraftsToLocalRepository(store: WorkbenchStore) async -> BatchLocalWriteResult {
    store.refreshBatchPublishPlan()

    guard let batchPublishPlan else {
      publishActionMessage = "没有可写入的批量发布计划。"
      return BatchLocalWriteResult(writtenDraftCount: 0, writtenPaths: [], skippedCount: 0)
    }

    let writableItems = batchPublishPlan.writableItems
    guard !writableItems.isEmpty else {
      publishActionMessage = "当前没有可批量写入的文章；请先处理阻塞问题、需确认项或确认文件变化。"
      return BatchLocalWriteResult(
        writtenDraftCount: 0,
        writtenPaths: [],
        skippedCount: batchPublishPlan.items.count
      )
    }

    let access = store.consumeFeatureUse(.batchPublishing)
    guard access.isAllowed else {
      publishActionMessage = access.message
      return BatchLocalWriteResult(writtenDraftCount: 0, writtenPaths: [], skippedCount: batchPublishPlan.items.count)
    }

    let profile = store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      publishActionMessage = "已有本地仓库写入或提交任务正在运行，请等待完成。"
      return BatchLocalWriteResult(
        writtenDraftCount: 0,
        writtenPaths: [],
        skippedCount: batchPublishPlan.items.count
      )
    }
    defer { finishLocalRepositoryMutation(operation) }
    publishActionMessage = "正在后台批量写入本地仓库…"

    var writtenItems: [BatchPublishPlanItem] = []
    var writtenPaths: [String] = []
    var failedTitles: [String] = []

    for item in writableItems {
      do {
        let paths = try await localPublishPreviewService.writeAsync(
          package: item.package,
          profile: profile
        )
        writtenItems.append(item)
        writtenPaths.append(contentsOf: paths)
      } catch {
        failedTitles.append("\(item.draftTitle)：\(error.localizedDescription)")
      }
    }

    if !writtenItems.isEmpty {
      releaseRecords.insert(
        .batchLocalWrite(profile: profile, items: writtenItems, writtenPaths: writtenPaths),
        at: 0
      )
      store.save()
    }
    let stillCurrent = localRepositoryMutationContext == operation
      && store.profiles.first(where: { $0.id == profile.id }).map(operation.stillMatches) == true
      && store.activeProfileID == profile.id
    if stillCurrent {
      store.requestRepositoryScan()
    }

    let result = BatchLocalWriteResult(
      writtenDraftCount: writtenItems.count,
      writtenPaths: writtenPaths,
      failedTitles: failedTitles,
      skippedCount: batchPublishPlan.items.count - writableItems.count
    )

    if !stillCurrent {
      publishActionMessage = "原站点批量写入完成：成功 \(result.writtenDraftCount) 篇、失败 \(failedTitles.count) 篇；当前站点已变化。"
    } else if failedTitles.isEmpty {
      publishActionMessage = "已批量写入 \(result.writtenDraftCount) 篇、\(result.writtenPaths.count) 个文件。"
    } else {
      publishActionMessage = "已写入 \(result.writtenDraftCount) 篇，\(failedTitles.count) 篇失败：\(failedTitles.joined(separator: "；"))"
    }

    return result
  }

  @discardableResult
  public func publishBatchReadyDraftsOnlineUsingPreferredStrategy(
    store: WorkbenchStore
  ) async -> RemoteRepositoryPublishResult? {
    guard store.canUseProtectedWorkbench else {
      publishActionMessage = store.privacyLockedOperationMessage
      return nil
    }

    store.refreshBatchPublishPlan()

    guard let batchPublishPlan else {
      publishActionMessage = "没有可线上发布的批量队列。"
      return nil
    }

    let publishableItems = batchPublishPlan.remotePublishableItems
    guard !publishableItems.isEmpty else {
      publishActionMessage = "当前没有可批量线上发布的文章；请先处理阻塞问题、需确认项或确认文件变化。"
      return nil
    }

    let profile = store.activeProfile
    let mode = preferredRemoteRepositoryPublishMode(for: profile)
    guard let package = remotePublishPackage(for: batchPublishPlan, profile: profile) else {
      publishActionMessage = "批量队列没有可上传的文件。"
      return nil
    }

    let batchAccess = store.canStartFeatureUse(.batchPublishing)
    guard batchAccess.isAllowed else {
      publishActionMessage = batchAccess.message
      return nil
    }
    let onlineAccess = store.canStartFeatureUse(.onlinePublishing)
    guard onlineAccess.isAllowed else {
      publishActionMessage = onlineAccess.message
      return nil
    }

    let preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: batchPublishPlan),
      store: store
    )
    guard preview.hasToken else {
      publishActionMessage = "仓库访问 Token 未保存，无法批量线上发布。"
      return nil
    }
    guard preview.blockingIssues.isEmpty else {
      publishActionMessage = blockedLocalPublishMessage(action: "批量线上发布", issues: preview.blockingIssues)
      return nil
    }
    guard preview.accessCheck != nil else {
      publishActionMessage = "请先检查 \(profile.repositoryProvider.displayName) Token 权限，确认具备写入权限后再批量线上发布。"
      return nil
    }
    guard preview.canPublish else {
      publishActionMessage = "Token 权限未通过，无法批量线上发布。"
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    let consumedBatchAccess = store.consumeFeatureUse(.batchPublishing)
    guard consumedBatchAccess.isAllowed else {
      publishActionMessage = consumedBatchAccess.message
      return nil
    }
    let consumedOnlineAccess = store.consumeFeatureUse(.onlinePublishing)
    guard consumedOnlineAccess.isAllowed else {
      publishActionMessage = consumedOnlineAccess.message
      return nil
    }

    selectedSection = .sync
    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      publishActionMessage = "已有远端仓库操作正在运行，请等待完成。"
      return nil
    }
    store.setRemoteRepositoryPublishProgress(nil)
    publishActionMessage = "正在通过 \(profile.repositoryProvider.displayName) 批量执行\(mode.displayName)..."
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let progressHandler: @Sendable (RemoteRepositoryPublishProgress) -> Void = { [weak self, weak store] progress in
        Task { @MainActor in
          guard let self, let store,
                self.remoteRepositoryMutationIsCurrent(operation, store: store) else { return }
          store.setRemoteRepositoryPublishProgress(progress)
        }
      }
      let result = try await remoteRepositoryPublishService.publish(
        package: package,
        profile: profile,
        mode: mode,
        token: token,
        onProgress: progressHandler
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryPublishResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let releaseRecord = ReleaseRecord.batchRemotePublish(
        profile: profile,
        items: publishableItems,
        result: result
      )
      releaseRecords.insert(releaseRecord, at: 0)
      markDraftsAsPublishedIfDirectRemoteCommit(
        mode: mode,
        draftIDs: publishableItems.map(\.draftID)
      )
      store.recordRemoteRepositoryPublishInAutoSync(result)
      publishActionMessage = "批量\(mode.displayName)完成：\(publishableItems.count) 篇、\(result.changedPaths.count) 个文件。"
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      if store.remoteRepositoryPublishProgress?.stage != .completed {
        store.setRemoteRepositoryPublishProgress(.init(
          stage: .completed,
          progress: 1,
          message: "批量发布完成",
          detail: "发布流程已结束"
        ))
      }
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      let message = "批量\(mode.displayName)失败：\(error.localizedDescription)"
      let partialFailure = partialRemoteRepositoryPublishFailure(from: error)
      store.setRemoteRepositoryPublishProgress(.init(
        stage: .failed,
        progress: nil,
        message: "批量发布失败",
        detail: error.localizedDescription
      ))
      let releaseRecord = ReleaseRecord.batchRemotePublishFailure(
        package: package,
        profile: profile,
        items: publishableItems,
        mode: mode,
        errorMessage: message,
        changedPaths: partialFailure?.changedPaths,
        commitSHA: partialFailure?.commitSHA
      )
      releaseRecords.insert(releaseRecord, at: 0)
      publishActionMessage = message
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(releaseRecord) {
        await store.refreshDeploymentStatus(for: releaseRecord, updatesMessage: false)
      }
      store.save()
      return nil
    }
  }

}
