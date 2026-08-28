import Foundation

extension PublishingStore {
  public func localSitePreviewPlan(for draft: ArticleDraft, store: WorkbenchStore)
    -> LocalSitePreviewPlan?
  {
    let profile = store.profile(for: draft)
    let profileRootPath = profile.localRepositoryRootURL?
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    let currentPlanRootPath = localSitePreviewPlan.map {
      URL(fileURLWithPath: $0.rootPath, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    }
    if let currentPlan = localSitePreviewPlan,
       profile.id == store.activeProfileID,
       currentPlan.executionIdentity?.profileID == profile.id,
       let profileRootPath,
       let currentPlanRootPath,
       currentPlanRootPath == profileRootPath {
      return currentPlan
    }
    return localSitePreviewService.plan(profile: profile)
  }

  public func localSitePreviewURL(for draft: ArticleDraft, store: WorkbenchStore) -> URL? {
    let profile = store.profile(for: draft)
    guard let plan = localSitePreviewPlan(for: draft, store: store) else { return nil }
    return localSitePreviewService.previewURL(for: draft, profile: profile, plan: plan)
  }

  public func refreshLocalSitePreviewPlan(for profile: SiteProfile) {
    refreshLocalSitePreviewPlan(for: profile, repositoryReport: nil)
  }

  public func refreshLocalSitePreviewPlan(
    for profile: SiteProfile,
    repositoryReport: RepositoryScanReport?
  ) {
    let expectedSiteKind = repositoryReport?.detectedKind ?? profile.siteKind
    let profileRootPath = profile.localRepositoryRootURL?
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    let currentPlanRootPath = localSitePreviewPlan.map {
      URL(fileURLWithPath: $0.rootPath, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    }
    if localSitePreviewRuntimeStatus.isRunning,
       let currentPlan = localSitePreviewPlan,
       currentPlan.executionIdentity?.profileID == profile.id,
       let profileRootPath,
       let currentPlanRootPath,
       currentPlan.siteKind == expectedSiteKind,
       currentPlanRootPath == profileRootPath,
       localSitePreviewProcessService.isExecutionCurrent(for: currentPlan) {
      return
    }
    let updatedPlan = localSitePreviewService.plan(
      profile: profile,
      repositoryReport: repositoryReport
    )
    guard updatedPlan != localSitePreviewPlan else { return }

    // Replacing the plan invalidates every delayed start/reachability task,
    // even when no preview process is currently running.
    localSitePreviewGeneration &+= 1

    if let currentPlan = localSitePreviewPlan,
      let currentIdentity = currentPlan.executionIdentity,
      let profileRootPath,
      currentIdentity.profileID == profile.id,
      currentIdentity.canonicalRootPath == profileRootPath,
      currentIdentity.fingerprint != updatedPlan?.executionIdentity?.fingerprint
    {
      localSitePreviewProcessService.invalidateAuthorization(for: currentPlan)
    }

    if localSitePreviewRuntimeStatus.isRunning {
      requestLocalSitePreviewStop(message: "站点预览配置已变更，正在停止原来的本地预览。")
    }

    stopLocalSitePreviewFileWatcher()
    localSitePreviewPlan = updatedPlan
  }

  public func stopLocalSitePreview() {
    requestLocalSitePreviewStop(message: "正在停止本地预览。")
  }

  public func stopLocalSitePreviewImmediately() {
    localSitePreviewGeneration &+= 1
    stopLocalSitePreviewFileWatcher()
    localSitePreviewProcessService.stop()
    localSitePreviewStopTask = nil
    localSitePreviewStopOperationID = nil
    localSitePreviewRuntimeStatus = .stopped
  }

  public func refreshLocalSitePreviewRuntimeStatus() {
    localSitePreviewRuntimeStatus = localSitePreviewProcessService.status
  }

  public func reloadLocalSitePreview() {
    guard localSitePreviewRuntimeStatus.isRunning else { return }
    localSitePreviewRefreshToken &+= 1
  }

  public func verifyLocalSitePreviewReachability() async {
    guard
      let previewURL = localSitePreviewRuntimeStatus.previewURL ?? localSitePreviewPlan?.previewURL
    else {
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

  @discardableResult
  public func startLocalSitePreview() -> LocalSitePreviewStartDisposition {
    guard let plan = localSitePreviewPlan else {
      localSitePreviewRuntimeStatus = .stopped
      setPublishActionMessage(
        "请先为当前站点选择本地仓库，才能启动本地预览。",
        status: .warning
      )
      return .failed(CoreL10n.text("请先为当前站点选择本地仓库，才能启动本地预览。"))
    }
    guard plan.executionIdentity?.profileID == activeProfileID else {
      let message = CoreL10n.text("本地预览计划不属于当前站点，请重新检查后再启动。")
      setPublishActionMessage(message, status: .warning)
      return .failed(message)
    }
    guard plan.diagnostics.isReadyToStart else {
      let message = plan.diagnostics.blockingMessages.first
        ?? CoreL10n.text("本地预览依赖检查未通过。")
      setPublishActionMessage(message, status: .warning)
      return .failed(message)
    }

    do {
      if let request = try localSitePreviewProcessService.authorizationRequest(for: plan) {
        let message = CoreL10n.text("请确认仓库路径和启动命令后再运行本地预览。")
        localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
          isRunning: false,
          previewURL: plan.previewURL,
          message: message
        )
        setPublishActionMessage(message, status: .warning)
        return .needsConfirmation(request)
      }
    } catch {
      let message = error.localizedDescription
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: plan.previewURL,
        message: message
      )
      setPublishActionMessage(message, status: .failure)
      return .failed(message)
    }

    localSitePreviewGeneration &+= 1
    let generation = localSitePreviewGeneration
    if let stopTask = localSitePreviewStopTask {
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: plan.previewURL,
        message: "正在等待原来的本地预览停止。"
      )
      setPublishActionMessage(localSitePreviewRuntimeStatus.message, status: .inProgress)
      Task { [weak self] in
        await stopTask.value
        guard let self, self.isCurrentLocalSitePreviewStart(plan: plan, generation: generation)
        else { return }
        self.startLocalSitePreview(plan: plan, generation: generation)
      }
      return .started
    }

    startLocalSitePreview(plan: plan, generation: generation)
    return localSitePreviewRuntimeStatus.isRunning
      ? .started
      : .failed(localSitePreviewRuntimeStatus.message)
  }

  @discardableResult
  public func authorizeAndStartLocalSitePreview(
    _ request: LocalSitePreviewAuthorizationRequest
  ) -> LocalSitePreviewStartDisposition {
    guard let plan = localSitePreviewPlan else {
      return .failed(CoreL10n.text("本地预览计划已失效，请重新检查。"))
    }
    guard
      plan.executionIdentity?.profileID == activeProfileID,
      request.profileID == activeProfileID
    else {
      let message = CoreL10n.text("当前站点已变更，旧的本地预览确认已失效。")
      setPublishActionMessage(message, status: .warning)
      return .failed(message)
    }
    do {
      try localSitePreviewProcessService.authorize(plan: plan, matching: request)
    } catch {
      let message = error.localizedDescription
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: plan.previewURL,
        message: message
      )
      setPublishActionMessage(message, status: .failure)
      return .failed(message)
    }
    return startLocalSitePreview()
  }

  private func startLocalSitePreview(plan: LocalSitePreviewPlan, generation: UInt64) {
    guard isCurrentLocalSitePreviewStart(plan: plan, generation: generation) else { return }
    do {
      localSitePreviewRuntimeStatus = try localSitePreviewProcessService.start(plan: plan)
      startLocalSitePreviewFileWatcher(for: plan, generation: generation)
      setPublishActionMessage(localSitePreviewRuntimeStatus.message, status: .inProgress)
      Task { [weak self] in
        for _ in 0..<5 {
          try? await Task.sleep(for: .seconds(1))
          guard let self,
            self.localSitePreviewGeneration == generation,
            self.localSitePreviewRuntimeStatus.isRunning
          else { return }
          await self.verifyLocalSitePreviewReachability()
          if self.localSitePreviewRuntimeStatus.isReachable { return }
        }
      }
    } catch {
      stopLocalSitePreviewFileWatcher()
      let message = "本地预览启动失败：\(error.localizedDescription)"
      localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: plan.previewURL,
        message: message
      )
      setPublishActionMessage(message, status: .failure)
    }
  }

  private func isCurrentLocalSitePreviewStart(
    plan: LocalSitePreviewPlan,
    generation: UInt64
  ) -> Bool {
    guard
      localSitePreviewGeneration == generation,
      localSitePreviewPlan == plan,
      let identity = plan.executionIdentity,
      identity.profileID == activeProfileID
    else {
      return false
    }
    return localSitePreviewProcessService.isExecutionCurrent(for: plan)
  }

  private func startLocalSitePreviewFileWatcher(
    for plan: LocalSitePreviewPlan,
    generation: UInt64
  ) {
    stopLocalSitePreviewFileWatcher()
    let watcher = LocalSitePreviewFileWatcher(
      rootPath: plan.rootPath,
      siteKind: plan.siteKind,
      expectedExecutionManifestDigest: plan.executionIdentity?.manifestDigest
    ) { [weak self] change in
      Task { @MainActor [weak self] in
        guard let self, self.localSitePreviewGeneration == generation else { return }
        if change.executionConfigurationChanged {
          guard self.localSitePreviewProcessService.isExecutionCurrent(for: plan) else {
            self.localSitePreviewProcessService.invalidateAuthorization(for: plan)
            self.requestLocalSitePreviewStop(
              message: CoreL10n.text("预览启动命令或项目清单已变更，已停止旧预览；下次启动需重新确认。")
            )
            return
          }
        }
        self.refreshLocalSitePreview(generation: generation)
      }
    }
    watcher.start()
    localSitePreviewFileWatcher = watcher
  }

  private func stopLocalSitePreviewFileWatcher() {
    localSitePreviewFileWatcher?.stop()
    localSitePreviewFileWatcher = nil
  }

  private func refreshLocalSitePreview(generation: UInt64) {
    guard localSitePreviewGeneration == generation,
      localSitePreviewRuntimeStatus.isRunning
    else { return }
    localSitePreviewRefreshToken &+= 1
    localSitePreviewRuntimeStatus.message = "检测到仓库文件变更，预览已刷新。"
    setPublishActionMessage(
      localSitePreviewRuntimeStatus.message,
      status: .success
    )
  }

  private func requestLocalSitePreviewStop(message: String) {
    guard localSitePreviewStopTask == nil else {
      setPublishActionMessage(message, status: .inProgress)
      return
    }

    localSitePreviewGeneration &+= 1
    let generation = localSitePreviewGeneration
    let operationID = UUID()
    let previewURL = localSitePreviewRuntimeStatus.previewURL ?? localSitePreviewPlan?.previewURL
    localSitePreviewStopOperationID = operationID
    stopLocalSitePreviewFileWatcher()
    localSitePreviewRuntimeStatus = LocalSitePreviewRuntimeStatus(
      isRunning: false,
      previewURL: previewURL,
      message: "正在停止本地预览。"
    )
    setPublishActionMessage(message, status: .inProgress)

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

}
