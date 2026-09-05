import Foundation

struct DirectRemotePublishFreshnessInspection {
  var reconciledPackage: PublishPackage
  var adoptedPathCount: Int
  var conflictSession: RemoteRepositoryConflictSession?
  var conflictPaths: [String]
  var conflictDetails: String
}

extension PublishingStore {
  func isRemoteVersionConflictError(_ error: Error) -> Bool {
    switch error {
    case RemoteRepositoryPublishError.untrackedRemoteFile,
      RemoteRepositoryPublishError.remoteVersionConflict:
      return true
    default:
      return false
    }
  }

  func refreshedRemoteConflictSessionAfterVersionRace(
    package: PublishPackage,
    scope: RemoteRepositoryConflictPublishScope,
    profile: SiteProfile
  ) async -> RemoteRepositoryConflictSession? {
    do {
      let token = try repositoryAccessToken(for: profile)
      var session = try await remoteRepositoryPublishService.conflictResolutionSession(
        package: package,
        profile: profile,
        token: token
      )
      guard !session.isEmpty else { return nil }
      session.publishScope = scope
      session.packageFingerprint = remoteRepositoryPublishService.conflictPackageFingerprint(
        package: package,
        profile: profile
      )
      return session
    } catch {
      // The caller retains and reports the original compare-and-swap error if
      // the best-effort diagnostic refresh cannot produce a conflict session.
      return nil
    }
  }

  /// Repository-report conflicts are useful early warnings, but the provider
  /// API is the authoritative source at the publish boundary. Keep all other
  /// blockers while allowing an exact, read-only API preflight to replace a
  /// stale local warning with current evidence.
  func blockingIssuesBeforeAuthoritativeRemotePreflight(
    _ preview: RemoteRepositoryPublishPreview
  ) -> [PreflightIssue] {
    preview.blockingIssues.filter { !isRemoteFreshnessIssue($0) }
  }

  func isRemoteFreshnessIssue(_ issue: PreflightIssue) -> Bool {
    if issue.field == "remoteBaseline" {
      return true
    }
    guard issue.field == "repository" else { return false }
    return issue.title == CoreL10n.text("远端同路径变更")
      || issue.title == CoreL10n.text("远端状态待确认")
  }

  func inspectDirectRemotePublishFreshness(
    package: PublishPackage,
    sourcePackages: [PublishPackage],
    scope: RemoteRepositoryConflictPublishScope,
    profile: SiteProfile,
    token: String?,
    store: WorkbenchStore
  ) async throws -> DirectRemotePublishFreshnessInspection {
    let inspection = try await remoteRepositoryPublishService.preflightInspection(
      package: package,
      profile: profile,
      token: token
    )
    let preflight = inspection.result
    let adoptedPathCount = confirmDirectRemotePublishPreflightAdoptions(
      packages: sourcePackages,
      preflight: preflight,
      profile: profile,
      store: store
    )
    let reconciledPackage = packageApplyingRemotePublishPreflight(preflight, to: package)
    var conflictSession: RemoteRepositoryConflictSession?
    if !preflight.conflicts.isEmpty {
      var session = try await remoteRepositoryPublishService.conflictResolutionSession(
        inspection: inspection,
        profile: profile,
        token: token
      )
      session.publishScope = scope
      // Identical files may have gained verified SHAs just above. Freeze the
      // reconciled package fingerprint so opening the resolver does not
      // invalidate a valid mixed adoption/conflict session.
      session.packageFingerprint = remoteRepositoryPublishService.conflictPackageFingerprint(
        package: reconciledPackage,
        profile: profile
      )
      conflictSession = session
    }
    return DirectRemotePublishFreshnessInspection(
      reconciledPackage: reconciledPackage,
      adoptedPathCount: adoptedPathCount,
      conflictSession: conflictSession,
      conflictPaths: preflight.conflicts.map(\.repositoryPath),
      conflictDetails: preflight.conflicts
        .map { $0.error.localizedDescription }
        .joined(separator: "；")
    )
  }

  func markRemotePublishPreflightConflicts(
    paths: [String],
    packages: [PublishPackage]
  ) {
    let normalizedPaths = Set(paths.map { $0.normalizedRelativePath() })
    let conflictedIDs = Set(
      packages.compactMap { package -> UUID? in
        package.files.contains {
          normalizedPaths.contains($0.repositoryPath.normalizedRelativePath())
        } ? package.draftID : nil
      }
    )
    markDraftsRepositorySyncState(.diverged, draftIDs: conflictedIDs)
  }

  func remoteFreshnessConflictMessage(
    action: String,
    inspection: DirectRemotePublishFreshnessInspection
  ) -> String {
    let adoptionSummary =
      inspection.adoptedPathCount > 0
      ? CoreL10n.format(
        "；已安全补认 %lld 个内容一致的远端文件",
        inspection.adoptedPathCount
      )
      : ""
    return CoreL10n.format(
      "检测到其他软件已更新远端，%@已在任何写入前停止：%@%@",
      action,
      inspection.conflictDetails,
      adoptionSummary
    )
  }

  func updateRemotePublishPreviewAfterAuthoritativePreflight(
    _ preview: inout RemoteRepositoryPublishPreview,
    conflictPaths: [String],
    conflictMessage: String? = nil
  ) {
    let normalizedPaths = Array(
      Set(conflictPaths.map { $0.normalizedRelativePath() })
    ).sorted()
    preview.remoteConflictPaths = normalizedPaths
    preview.remoteRiskState = normalizedPaths.isEmpty ? .clean : .conflict
    preview.blockingIssues.removeAll(where: isRemoteFreshnessIssue)
    preview.warningIssues.removeAll(where: isRemoteFreshnessIssue)
    if let conflictMessage, !normalizedPaths.isEmpty {
      preview.blockingIssues.append(
        PreflightIssue(
          severity: .error,
          title: CoreL10n.text("远端同路径变更"),
          message: conflictMessage,
          field: "remoteBaseline"
        )
      )
    }
  }

  func updateDraftRemotePublishPreviewAfterAuthoritativePreflight(
    draftID: UUID,
    conflictPaths: [String],
    conflictMessage: String? = nil
  ) {
    guard let snapshot = draftPublishPreviewSnapshot(for: draftID) else { return }
    var preview = snapshot.remotePublishPreview
    updateRemotePublishPreviewAfterAuthoritativePreflight(
      &preview,
      conflictPaths: conflictPaths,
      conflictMessage: conflictMessage
    )
    _ = installDraftPublishPreviewSnapshot(
      DraftPublishPreviewSnapshot(
        context: snapshot.context,
        publishPackage: snapshot.publishPackage,
        localPublishPreview: snapshot.localPublishPreview,
        localPublishReadiness: snapshot.localPublishReadiness,
        remotePublishPreview: preview,
        remoteReviewDraft: snapshot.remoteReviewDraft
      ),
      for: draftID
    )
  }

  func updateBatchRemotePublishPreviewAfterAuthoritativePreflight(
    conflictPaths: [String],
    conflictMessage: String? = nil
  ) {
    guard var preview = batchRemotePublishPreviewSnapshot else { return }
    updateRemotePublishPreviewAfterAuthoritativePreflight(
      &preview,
      conflictPaths: conflictPaths,
      conflictMessage: conflictMessage
    )
    batchRemotePublishPreviewSnapshot = preview
  }

  /// Performs the complete read-only freshness boundary used before the
  /// single-article confirmation sheet is shown. A conflict creates a scoped
  /// resolver session and returns false; no remote mutation is attempted.
  @discardableResult
  public func prepareSelectedDraftOnlinePublish(
    draftID: UUID,
    store: WorkbenchStore
  ) async -> Bool {
    guard !blockPublishingIfGeneralDraftSelected(store: store) else { return false }
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }

    let refresh = await store.refreshRepositoryStateForPublishing()
    guard !Task.isCancelled else { return false }
    guard refresh != nil else {
      setPublishActionMessage(
        CoreL10n.text("当前站点或仓库已变化，请重新发起发布。"),
        status: .warning
      )
      return false
    }
    _ = await store.refreshPublishPreview(for: draftID)
    guard !Task.isCancelled,
      let draft = drafts.first(where: { $0.id == draftID }),
      draft.belongs(toSiteProfileID: store.activeProfileID)
    else { return false }

    var profile = store.profile(for: draft)
    var package = publishingPackage(for: draft, store: store)
    var mode = preferredRemoteRepositoryPublishMode(for: profile)
    var preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      store: store
    )
    guard validateRemotePublishPreparationPreview(preview, action: "线上发布") else {
      return false
    }
    guard await store.ensureRemoteRepositoryWriteAccess(for: profile) else { return false }
    guard !Task.isCancelled,
      let refreshedDraft = drafts.first(where: { $0.id == draftID })
    else { return false }

    profile = store.profile(for: refreshedDraft)
    package = publishingPackage(for: refreshedDraft, store: store)
    mode = preferredRemoteRepositoryPublishMode(for: profile)
    preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      store: store
    )
    guard validateRemotePublishPreparationPreview(preview, action: "线上发布") else {
      return false
    }
    guard mode == .directCommit else {
      _ = await store.refreshPublishPreview(for: draftID)
      return true
    }

    guard remoteRepositoryMutationContext == nil,
      let operation = beginRemoteRepositoryMutation(profile: profile, store: store)
    else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return false
    }
    setPublishActionMessage(
      CoreL10n.text("正在检查其他软件产生的远端更新…"),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let inspection = try await inspectDirectRemotePublishFreshness(
        package: package,
        sourcePackages: [package],
        scope: .selectedDraft(draftID),
        profile: profile,
        token: token,
        store: store
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return false }
      if let conflictSession = inspection.conflictSession {
        remoteRepositoryConflictSession = conflictSession
        markRemotePublishPreflightConflicts(
          paths: inspection.conflictPaths,
          packages: [package]
        )
        let message = remoteFreshnessConflictMessage(
          action: CoreL10n.text("单篇发布"),
          inspection: inspection
        )
        updateDraftRemotePublishPreviewAfterAuthoritativePreflight(
          draftID: draftID,
          conflictPaths: inspection.conflictPaths,
          conflictMessage: message
        )
        setPublishActionMessage(message, status: .warning)
        store.save()
        return false
      }

      remoteRepositoryConflictSession = nil
      if inspection.adoptedPathCount > 0 {
        store.save()
        _ = await store.refreshPublishPreview(for: draftID)
      }
      updateDraftRemotePublishPreviewAfterAuthoritativePreflight(
        draftID: draftID,
        conflictPaths: []
      )
      let fetchWarning =
        refresh?.status == .failed
        ? CoreL10n.format("；本地 fetch 失败，但远端 API 已完成逐文件核对：%@", refresh?.message ?? "")
        : ""
      setPublishActionMessage(
        CoreL10n.format("已核对远端最新版本，可进入发布确认%@", fetchWarning),
        status: refresh?.status == .failed ? .warning : .success
      )
      return true
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return false }
      setPublishActionMessage(
        CoreL10n.format("刷新远端版本失败：%@", error.localizedDescription),
        status: .failure
      )
      return false
    }
  }

  /// Batch counterpart of `prepareSelectedDraftOnlinePublish`. The complete
  /// package is inspected before its immutable confirmation snapshot is made.
  @discardableResult
  public func prepareBatchOnlinePublish(store: WorkbenchStore) async -> Bool {
    guard store.canUseProtectedWorkbench else {
      setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return false
    }
    let refresh = await store.refreshRepositoryStateForPublishing()
    guard !Task.isCancelled else { return false }
    guard refresh != nil else {
      setPublishActionMessage(
        CoreL10n.text("当前站点或仓库已变化，请重新发起发布。"),
        status: .warning
      )
      return false
    }
    await store.refreshBatchPublishPlanAsync()
    guard !Task.isCancelled,
      var plan = batchPublishPlan,
      !plan.remotePublishableItems.isEmpty,
      var package = remotePublishPackage(for: plan)
    else { return false }

    var profile = store.activeProfile
    var mode = preferredRemoteRepositoryPublishMode(for: profile)
    var preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
      store: store
    )
    guard validateRemotePublishPreparationPreview(preview, action: "批量线上发布") else {
      return false
    }
    guard await store.ensureRemoteRepositoryWriteAccess(for: profile) else { return false }
    guard !Task.isCancelled else { return false }
    await store.refreshBatchPublishPlanAsync()
    guard let refreshedPlan = batchPublishPlan,
      !refreshedPlan.remotePublishableItems.isEmpty,
      let refreshedPackage = remotePublishPackage(for: refreshedPlan)
    else { return false }
    plan = refreshedPlan
    package = refreshedPackage
    profile = store.activeProfile
    mode = preferredRemoteRepositoryPublishMode(for: profile)
    preview = remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: batchRemoteRepositoryPublishWarningIssues(for: plan),
      store: store
    )
    guard validateRemotePublishPreparationPreview(preview, action: "批量线上发布") else {
      return false
    }
    guard mode == .directCommit else { return true }

    guard remoteRepositoryMutationContext == nil,
      let operation = beginRemoteRepositoryMutation(profile: profile, store: store)
    else {
      setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return false
    }
    setPublishActionMessage(
      CoreL10n.text("正在检查整批文件的远端最新版本…"),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let token = try repositoryAccessToken(for: profile)
      let sourcePackages = plan.remotePublishableItems.map(\.package)
      let scope = RemoteRepositoryConflictPublishScope.batch(
        plan.remotePublishableItems.map(\.draftID)
      )
      let inspection = try await inspectDirectRemotePublishFreshness(
        package: package,
        sourcePackages: sourcePackages,
        scope: scope,
        profile: profile,
        token: token,
        store: store
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return false }
      if let conflictSession = inspection.conflictSession {
        remoteRepositoryConflictSession = conflictSession
        markRemotePublishPreflightConflicts(
          paths: inspection.conflictPaths,
          packages: sourcePackages
        )
        let message = remoteFreshnessConflictMessage(
          action: CoreL10n.text("全部文件发布"),
          inspection: inspection
        )
        updateBatchRemotePublishPreviewAfterAuthoritativePreflight(
          conflictPaths: inspection.conflictPaths,
          conflictMessage: message
        )
        setPublishActionMessage(message, status: .warning)
        store.save()
        return false
      }

      remoteRepositoryConflictSession = nil
      if inspection.adoptedPathCount > 0 {
        store.save()
        await store.refreshBatchPublishPlanAsync()
      }
      updateBatchRemotePublishPreviewAfterAuthoritativePreflight(conflictPaths: [])
      let fetchWarning =
        refresh?.status == .failed
        ? CoreL10n.format("；本地 fetch 失败，但远端 API 已完成逐文件核对：%@", refresh?.message ?? "")
        : ""
      setPublishActionMessage(
        CoreL10n.format("已核对整批远端版本，可进入发布确认%@", fetchWarning),
        status: refresh?.status == .failed ? .warning : .success
      )
      return true
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return false }
      setPublishActionMessage(
        CoreL10n.format("刷新整批远端版本失败：%@", error.localizedDescription),
        status: .failure
      )
      return false
    }
  }

  private func validateRemotePublishPreparationPreview(
    _ preview: RemoteRepositoryPublishPreview,
    action: String
  ) -> Bool {
    if let tokenAccessFailureMessage = preview.tokenAccessFailureMessage {
      setPublishActionMessage(
        CoreL10n.format("仓库 Token 状态读取失败：%@", tokenAccessFailureMessage),
        status: .failure
      )
      return false
    }
    guard preview.hasToken else {
      setPublishActionMessage(
        CoreL10n.text("仓库访问 Token 未保存，无法线上发布。"),
        status: .warning
      )
      return false
    }
    let blockingIssues = blockingIssuesBeforeAuthoritativeRemotePreflight(preview)
    guard blockingIssues.isEmpty else {
      setPublishActionMessage(
        blockedLocalPublishMessage(action: action, issues: blockingIssues),
        status: .warning
      )
      return false
    }
    return true
  }
}
