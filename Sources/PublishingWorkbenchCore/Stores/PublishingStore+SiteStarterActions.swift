import Foundation
import PublishingDomainContracts

/// The result of importing an existing site, separated from transient UI
/// feedback so callers can record an accurate operation outcome even if a
/// later action replaces the publish banner.
public enum SiteStarterImportOperationOutcome: Sendable {
  case succeeded(SiteStarterImportResult)
  case partiallySucceeded(SiteStarterImportResult)
  case cancelled
  case superseded
  case failed

  public var result: SiteStarterImportResult? {
    switch self {
    case .succeeded(let result), .partiallySucceeded(let result): result
    case .cancelled, .superseded, .failed: nil
    }
  }

  public var operationLogOutcome: WorkbenchOperationLogOutcome {
    switch self {
    case .succeeded: .succeeded
    case .partiallySucceeded: .partial
    case .cancelled, .superseded: .cancelled
    case .failed: .failed
    }
  }
}

private struct SiteStarterOperationBaseline: Equatable {
  let profiles: [SiteProfile]
  let activeProfileID: UUID
  let drafts: [ArticleDraft]
  let selectedDraftID: UUID?
  let siteStarterResult: SiteStarterResult?
  let siteStarterImportResult: SiteStarterImportResult?
  let siteStarterPushResult: SiteStarterPushResult?
  let siteStarterProgress: SiteStarterProgress?

  @MainActor
  init(store: PublishingStore) {
    profiles = store.profiles
    activeProfileID = store.activeProfileID
    drafts = store.drafts
    selectedDraftID = store.selectedDraftID
    siteStarterResult = store.siteStarterResult
    siteStarterImportResult = store.siteStarterImportResult
    siteStarterPushResult = store.siteStarterPushResult
    siteStarterProgress = store.siteStarterProgress
  }

  @MainActor
  func stillMatches(_ store: PublishingStore) -> Bool {
    self == SiteStarterOperationBaseline(store: store)
  }
}
extension PublishingStore {
  @discardableResult
  public func createSiteFromStarter(
    _ request: SiteStarterRequest,
    store: WorkbenchStore
  ) async -> SiteStarterResult? {
    siteStarterOperationGeneration &+= 1
    let generation = siteStarterOperationGeneration
    let baseline = SiteStarterOperationBaseline(store: self)
    isSiteStarterOperationRunning = true
    setPublishActionMessage(
      CoreL10n.text("正在后台创建 Starter 站点…"),
      status: .inProgress
    )
    defer {
      if siteStarterOperationGeneration == generation {
        isSiteStarterOperationRunning = false
      }
    }

    do {
      let result = try await siteStarterService.createSiteAsync(request: request)
      guard siteStarterOperationGeneration == generation else { return nil }
      guard baseline.stillMatches(self) else {
        setPublishActionMessage(
          CoreL10n.text(
            "Starter 文件已生成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
          ),
          status: .warning
        )
        return nil
      }
      siteStarterResult = result
      siteStarterImportResult = nil
      siteStarterPushResult = nil
      siteStarterProgress = SiteStarterProgress(
        profileID: result.profile.id,
        repositoryRootPath: result.profile.localRepositoryRootPath,
        templateID: request.templateID,
        initialDraftID: result.initialDraft.id,
        createdFilePaths: result.createdFilePaths,
        initializedGit: result.initializedGit,
        originConfigured: result.configuredRemoteURL != nil,
        siteDescription: request.siteDescription,
        deploymentTarget: request.deploymentTarget,
        configureOriginRemote: request.configureOriginRemote
      )
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      drafts.append(result.initialDraft)
      selectedDraftID = result.initialDraft.id
      setPublishActionMessage(
        CoreL10n.format("已创建 Starter 站点：%@。", result.profile.name),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard siteStarterOperationGeneration == generation else { return nil }
      setPublishActionMessage(
        CoreL10n.format(
          "创建 Starter 站点失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return nil
    }
  }

  @discardableResult
  public func importExistingSiteFromStarterOutcome(
    _ request: SiteStarterImportRequest,
    store: WorkbenchStore
  ) async -> SiteStarterImportOperationOutcome {
    siteStarterOperationGeneration &+= 1
    let generation = siteStarterOperationGeneration
    let baseline = SiteStarterOperationBaseline(store: self)
    isSiteStarterOperationRunning = true
    setPublishActionMessage(
      CoreL10n.text("正在后台读取并导入已有站点…"),
      status: .inProgress
    )
    defer {
      if siteStarterOperationGeneration == generation {
        isSiteStarterOperationRunning = false
      }
    }

    do {
      var result = try await siteStarterService.importExistingSiteAsync(request: request)
      let importedDrafts = try await localContentImportService.importDraftsAsync(
        profile: result.profile)
      guard let hydratedDrafts = await hydrateLocalRepositoryBaselinesAsync(
        importedDrafts,
        profile: result.profile,
        store: store
      ) else {
        return Task.isCancelled ? .cancelled : .superseded
      }
      guard siteStarterOperationGeneration == generation else {
        return Task.isCancelled ? .cancelled : .superseded
      }
      guard baseline.stillMatches(self) else {
        setPublishActionMessage(
          CoreL10n.text(
            "站点读取完成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
          ),
          status: .warning
        )
        return .superseded
      }
      profiles.append(result.profile)
      activeProfileID = result.profile.id
      let importSummary = mergeImportedDrafts(hydratedDrafts, store: store)
      result.importedDraftCount = importSummary.insertedCount
      result.updatedDraftCount = importSummary.updatedCount
      result.skippedPathCount = importSummary.skippedCount
      siteStarterImportResult = result
      siteStarterResult = nil
      siteStarterPushResult = nil
      selectedDraftID = store.visibleDrafts.first?.id
      if let issue = hydratedDrafts.issues.first {
        setPublishActionMessage(
          CoreL10n.format(
            "已添加站点“%@”，但文章读取未完成：%@",
            result.profile.name,
            issue.message
          ),
          status: .warning
        )
      } else {
        setPublishActionMessage(
          CoreL10n.format("已导入已有站点：%@。", result.profile.name),
          status: .success
        )
      }
      store.save()
      return hydratedDrafts.issues.isEmpty ? .succeeded(result) : .partiallySucceeded(result)
    } catch {
      guard siteStarterOperationGeneration == generation else {
        return Task.isCancelled ? .cancelled : .superseded
      }
      setPublishActionMessage(
        CoreL10n.format(
          "导入已有站点失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return Task.isCancelled ? .cancelled : .failed
    }
  }

  /// Compatibility convenience for callers that only need the accepted
  /// import value. New orchestration and logging code should use the typed
  /// outcome above rather than inspecting global publish feedback.
  @discardableResult
  public func importExistingSiteFromStarter(
    _ request: SiteStarterImportRequest,
    store: WorkbenchStore
  ) async -> SiteStarterImportResult? {
    let outcome = await importExistingSiteFromStarterOutcome(request, store: store)
    return outcome.result
  }

  @discardableResult
  public func configureStarterSiteOrigin(store: WorkbenchStore) async -> Bool {
    guard var starterResult = siteStarterResult,
      starterResult.profile.id == store.activeProfileID
    else {
      setPublishActionMessage(
        CoreL10n.text(
          "没有可配置远端的 Starter 生成结果，请先创建站点。"
        ),
        status: .warning
      )
      return false
    }
    let profile = store.activeProfile
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        CoreL10n.text("已有本地仓库写入或提交任务正在运行，请等待完成。"),
        status: .warning
      )
      return false
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage(
      CoreL10n.text("正在配置 Starter 的 origin remote…"),
      status: .inProgress
    )

    do {
      let remoteURL = try await siteStarterService.configureGitHubOriginRemoteAsync(
        profile: profile)
      guard localRepositoryMutationContext == operation,
        operation.stillMatches(store.activeProfile)
      else {
        return false
      }
      starterResult.profile = profile
      starterResult.configuredRemoteURL = remoteURL
      siteStarterResult = starterResult
      if var progress = siteStarterProgress,
        let rootPath = SiteStarterProgress.normalizedRootPath(profile.localRepositoryRootPath),
        progress.profileID == profile.id,
        progress.repositoryRootPath == rootPath {
        progress.originConfigured = true
        siteStarterProgress = progress
      }
      setPublishActionMessage(
        CoreL10n.format(
          "已配置 Starter 远端：%@。",
          profile.repositoryDisplayName
        ),
        status: .success
      )
      store.save()
      return true
    } catch {
      guard localRepositoryMutationContext == operation,
        operation.stillMatches(store.activeProfile)
      else {
        return false
      }
      setPublishActionMessage(
        CoreL10n.format(
          "配置 Starter 远端失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return false
    }
  }

  @discardableResult
  public func prepareStarterSitePushConfirmation(
    store: WorkbenchStore
  ) async -> SiteStarterPushConfirmation? {
    guard let starterResult = siteStarterResult else {
      setPublishActionMessage(
        CoreL10n.text(
          "没有可复核的 Starter 生成结果，请先创建站点。"
        ),
        status: .warning
      )
      return nil
    }
    let profile = store.activeProfile
    guard profile.id == starterResult.profile.id,
      LocalRepositoryIdentity(profile: profile)
        == LocalRepositoryIdentity(profile: starterResult.profile)
    else {
      setPublishActionMessage(
        CoreL10n.text("当前站点或仓库目录已变化，请重新生成或导入站点后再复核。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        CoreL10n.text("已有本地仓库写入或提交任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage(
      CoreL10n.text("正在冻结首次推送复核内容…"),
      status: .inProgress
    )
    do {
      if let progress = siteStarterProgress,
        progress.localCommitSHA == nil,
        progress.frozenFirstPushRemoteURL != nil {
        let confirmation = try starterFrozenPushConfirmation(progress: progress, starterResult: starterResult)
        guard let recovered = try await siteStarterService.recoverCommittedStarterPush(
          profile: profile, confirmation: confirmation
        ) else {
          guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else {
            return nil
          }
          // The pre-commit persistence succeeded but no commit exists yet.
          // Discard that incomplete frozen attempt and permit a fresh review.
          var pendingProgress = progress
          pendingProgress.frozenPushConfirmation = nil
          pendingProgress.frozenFirstPushRemoteURL = nil
          pendingProgress.frozenFirstPushBranch = nil
          pendingProgress.frozenFirstPushHeadCommitSHA = nil
          pendingProgress.frozenFirstPushRemoteBranchCommitSHA = nil
          siteStarterProgress = pendingProgress
          guard store.saveCurrentStateSynchronously() else { return nil }
          let freshConfirmation = try await siteStarterService.prepareStarterPushConfirmationAsync(
            profile: profile, createdFilePaths: starterResult.createdFilePaths
          )
          guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else {
            return nil
          }
          return freshConfirmation
        }
        guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else {
          return nil
        }
        var recoveredProgress = progress
        recoveredProgress.firstPushStage = .committed
        recoveredProgress.localCommitSHA = recovered.commitSHA
        var recoveredConfirmation = confirmation
        recoveredConfirmation.existingCommitSHA = recovered.commitSHA
        recoveredProgress.frozenPushConfirmation = recoveredConfirmation
        siteStarterProgress = recoveredProgress
        guard store.saveCurrentStateSynchronously() else {
          setPublishActionMessage(CoreL10n.text("已找到 Starter 提交，但无法安全持久化 SHA，已停止推送。"), status: .failure)
          return nil
        }
        setPublishActionMessage(CoreL10n.text("已按冻结复核恢复 Starter 提交；确认后只会推送该 SHA。"), status: .warning)
        return recoveredConfirmation
      }
      if let progress = siteStarterProgress, let committedSHA = progress.localCommitSHA {
        let confirmation = try starterPushRetryConfirmation(progress: progress, starterResult: starterResult)
        _ = try await siteStarterService.validateCommittedStarterPush(
          profile: profile,
          confirmation: confirmation,
          committedPush: SiteStarterCommittedPush(
            commitSHA: committedSHA,
            committedPaths: starterResult.createdFilePaths
          ),
          at: try starterRepositoryRoot(profile: profile)
        )
        guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else {
          return nil
        }
        setPublishActionMessage(
          CoreL10n.text("已复核已提交的 Starter 版本；确认后只会推送该 SHA。"),
          status: .warning
        )
        return confirmation
      }
      let confirmation = try await siteStarterService.prepareStarterPushConfirmationAsync(
        profile: profile,
        createdFilePaths: starterResult.createdFilePaths
      )
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      setPublishActionMessage(
        CoreL10n.text("请复核冻结的远端、分支、提交说明和文件清单后再确认推送。"),
        status: .warning
      )
      return confirmation
    } catch {
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      setPublishActionMessage(
        CoreL10n.format(
          "Starter 首次推送复核失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return nil
    }
  }

  @discardableResult
  public func commitAndPushStarterSite(
    confirmation: SiteStarterPushConfirmation,
    store: WorkbenchStore
  ) async -> SiteStarterPushResult? {
    guard let starterResult = siteStarterResult else {
      setPublishActionMessage(
        CoreL10n.text("没有可提交的 Starter 生成结果，请先创建站点。"),
        status: .warning
      )
      return nil
    }
    let profile = store.activeProfile
    guard profile.id == starterResult.profile.id,
      LocalRepositoryIdentity(profile: profile)
        == LocalRepositoryIdentity(profile: starterResult.profile)
    else {
      setPublishActionMessage(
        CoreL10n.text("当前站点或仓库目录已变化，未提交或推送；请重新生成或导入站点。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginLocalRepositoryMutation(profile: profile) else {
      setPublishActionMessage(
        CoreL10n.text("已有本地仓库写入或提交任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    defer { finishLocalRepositoryMutation(operation) }
    setPublishActionMessage(CoreL10n.text("正在重新校验并推送 Starter…"), status: .inProgress)
    do {
      let progress = try starterProgressForPush(profile: profile)
      if let localCommitSHA = progress.localCommitSHA {
        let retryConfirmation = try starterPushRetryConfirmation(progress: progress, starterResult: starterResult)
        guard confirmation == retryConfirmation else { throw SiteStarterError.starterPushConfirmationChanged }
        // A prior persistence failure may have left this SHA only in memory.
        // Retry must durably save the same proof before any network push too.
        guard store.saveCurrentStateSynchronously() else {
          setPublishActionMessage(
            CoreL10n.text("Starter 已提交，但无法持久化提交 SHA；为避免推送未复核版本，已停止推送。"),
            status: .failure
          )
          return nil
        }
        let result = try await siteStarterService.pushCommittedStarterSiteAsync(
          profile: profile,
          confirmation: retryConfirmation,
          committedPush: SiteStarterCommittedPush(
            commitSHA: localCommitSHA,
            committedPaths: starterResult.createdFilePaths
          )
        )
        return finishStarterPush(
          rootPath: result.rootPath,
          branch: result.branch,
          remoteURL: result.remoteURL,
          commitSHA: localCommitSHA,
          committedPaths: starterResult.createdFilePaths,
          output: result.output,
          profile: profile,
          store: store,
          operation: operation
        )
      }

      var preparedProgress = progress
      preparedProgress.frozenFirstPushRemoteURL = confirmation.remoteURL
      preparedProgress.frozenFirstPushBranch = confirmation.branch
      preparedProgress.frozenFirstPushHeadCommitSHA = confirmation.headCommitSHA
      preparedProgress.frozenFirstPushRemoteBranchCommitSHA = confirmation.remoteBranchCommitSHA
      preparedProgress.frozenPushConfirmation = confirmation
      siteStarterProgress = preparedProgress
      guard store.saveCurrentStateSynchronously() else {
        setPublishActionMessage(CoreL10n.text("无法持久化首次推送复核，未提交或推送。"), status: .failure)
        return nil
      }

      let committed = try await siteStarterService.commitStarterSiteAsync(
        profile: profile, createdFilePaths: starterResult.createdFilePaths, confirmation: confirmation
      )
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      if var progress = siteStarterProgress,
        let rootPath = SiteStarterProgress.normalizedRootPath(profile.localRepositoryRootPath),
        progress.profileID == profile.id,
        progress.repositoryRootPath == rootPath {
        progress.firstPushStage = .committed
        progress.localCommitSHA = committed.commitSHA
        var committedConfirmation = confirmation
        committedConfirmation.existingCommitSHA = committed.commitSHA
        progress.frozenPushConfirmation = committedConfirmation
        siteStarterProgress = progress
      }
      guard store.saveCurrentStateSynchronously() else {
        setPublishActionMessage(
          CoreL10n.text("Starter 已提交，但无法持久化提交 SHA；为避免推送未复核版本，已停止推送。"),
          status: .failure
        )
        return nil
      }
      let result = try await siteStarterService.pushCommittedStarterSiteAsync(
        profile: profile, confirmation: try starterPushRetryConfirmation(
          progress: try starterProgressForPush(profile: profile), starterResult: starterResult
        ), committedPush: committed
      )
      return finishStarterPush(
        rootPath: result.rootPath, branch: result.branch, remoteURL: result.remoteURL,
        commitSHA: committed.commitSHA, committedPaths: committed.committedPaths, output: result.output,
        profile: profile, store: store, operation: operation
      )
    } catch {
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      setPublishActionMessage(
        CoreL10n.format("Starter 提交推送失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }

  private func starterProgressForPush(profile: SiteProfile) throws -> SiteStarterProgress {
    guard let progress = siteStarterProgress,
      progress.profileID == profile.id,
      progress.repositoryRootPath == SiteStarterProgress.normalizedRootPath(profile.localRepositoryRootPath)
    else { throw SiteStarterError.starterPushConfirmationChanged }
    return progress
  }

  private func starterRepositoryRoot(profile: SiteProfile) throws -> URL {
    guard let rootURL = profile.localRepositoryRootURL else { throw SiteStarterError.missingRepositoryRoot }
    return rootURL
  }

  private func starterPushRetryConfirmation(
    progress: SiteStarterProgress,
    starterResult: SiteStarterResult
  ) throws -> SiteStarterPushConfirmation {
    guard progress.localCommitSHA != nil else { throw SiteStarterError.starterPushConfirmationChanged }
    guard let confirmation = progress.frozenPushConfirmation,
      confirmation.existingCommitSHA == progress.localCommitSHA,
      confirmation.committedPaths == starterResult.createdFilePaths.sorted()
    else { throw SiteStarterError.starterPushConfirmationChanged }
    return confirmation
  }

  private func starterFrozenPushConfirmation(
    progress: SiteStarterProgress,
    starterResult: SiteStarterResult
  ) throws -> SiteStarterPushConfirmation {
    guard let confirmation = progress.frozenPushConfirmation,
      confirmation.existingCommitSHA == nil,
      confirmation.committedPaths == starterResult.createdFilePaths.sorted(),
      confirmation.fileObjectIDs.keys.sorted() == confirmation.committedPaths
    else { throw SiteStarterError.starterPushConfirmationChanged }
    return confirmation
  }

  private func finishStarterPush(
    rootPath: String,
    branch: String,
    remoteURL: String,
    commitSHA: String,
    committedPaths: [String],
    output: String,
    profile: SiteProfile,
    store: WorkbenchStore,
    operation: LocalRepositoryOperationContext
  ) -> SiteStarterPushResult? {
    guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile) else { return nil }
    let result = SiteStarterPushResult(
      rootPath: rootPath, branch: branch, remoteURL: remoteURL, commitSHA: commitSHA,
      committedPaths: committedPaths, output: output
    )
    siteStarterPushResult = result
    if var progress = siteStarterProgress,
      progress.profileID == profile.id,
      progress.repositoryRootPath == SiteStarterProgress.normalizedRootPath(profile.localRepositoryRootPath) {
      progress.firstPushStage = .completed
      siteStarterProgress = progress
    }
    setPublishActionMessage(CoreL10n.format("Starter 已提交并推送：%@。", String(commitSHA.prefix(8))), status: .success)
    store.save()
    return result
  }

  /// Rebuilds the wizard's transient result from the normal profile and draft
  /// snapshot after verifying that the same local directory still contains the
  /// saved, safe starter-file manifest.
  @discardableResult
  public func resumeSiteStarterProgress(store: WorkbenchStore) -> Bool {
    guard let progress = siteStarterProgress else { return false }
    guard let result = progress.resumedResult(
      activeProfile: store.activeProfile,
      drafts: drafts
    ) else {
      setPublishActionMessage(
        CoreL10n.text("当前站点或仓库目录已变化，请重新生成或导入站点后再复核。"),
        status: .warning
      )
      return false
    }
    siteStarterResult = result
    siteStarterImportResult = nil
    if progress.firstPushStage != .completed {
      siteStarterPushResult = nil
    }
    return true
  }
}
