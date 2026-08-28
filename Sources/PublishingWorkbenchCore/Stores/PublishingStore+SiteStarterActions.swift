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
  public func importExistingSiteFromStarter(
    _ request: SiteStarterImportRequest,
    store: WorkbenchStore
  ) async -> SiteStarterImportResult? {
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
        return nil
      }
      guard siteStarterOperationGeneration == generation else { return nil }
      guard baseline.stillMatches(self) else {
        setPublishActionMessage(
          CoreL10n.text(
            "站点读取完成，但工作台内容在操作期间发生变化，未覆盖当前状态。"
          ),
          status: .warning
        )
        return nil
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
      return result
    } catch {
      guard siteStarterOperationGeneration == generation else { return nil }
      setPublishActionMessage(
        CoreL10n.format(
          "导入已有站点失败：%@",
          error.localizedDescription
        ),
        status: .failure
      )
      return nil
    }
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
      let result = try await siteStarterService.commitAndPushStarterSiteAsync(
        profile: profile,
        createdFilePaths: starterResult.createdFilePaths,
        confirmation: confirmation
      )
      guard localRepositoryMutationContext == operation, operation.stillMatches(store.activeProfile)
      else {
        return nil
      }
      siteStarterPushResult = result
      setPublishActionMessage(
        CoreL10n.format("Starter 已提交并推送：%@。", String(result.commitSHA.prefix(8))),
        status: .success
      )
      store.save()
      return result
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
}
