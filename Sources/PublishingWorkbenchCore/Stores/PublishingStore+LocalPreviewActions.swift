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
       let profileRootPath,
       let currentPlanRootPath,
       currentPlan.siteKind == expectedSiteKind,
       currentPlanRootPath == profileRootPath {
      return
    }
    let updatedPlan = localSitePreviewService.plan(
      profile: profile,
      repositoryReport: repositoryReport
    )
    guard updatedPlan != localSitePreviewPlan else { return }

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
      startLocalSitePreviewFileWatcher(for: plan, generation: generation)
      publishActionMessage = localSitePreviewRuntimeStatus.message
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
      publishActionMessage = message
    }
  }

  private func startLocalSitePreviewFileWatcher(
    for plan: LocalSitePreviewPlan,
    generation: UInt64
  ) {
    stopLocalSitePreviewFileWatcher()
    let watcher = LocalSitePreviewFileWatcher(rootPath: plan.rootPath, siteKind: plan.siteKind) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.localSitePreviewGeneration == generation else { return }
        self.scheduleLocalSitePreviewRefresh(generation: generation)
      }
    }
    watcher.start()
    localSitePreviewFileWatcher = watcher
  }

  private func stopLocalSitePreviewFileWatcher() {
    localSitePreviewRefreshTask?.cancel()
    localSitePreviewRefreshTask = nil
    localSitePreviewFileWatcher?.stop()
    localSitePreviewFileWatcher = nil
  }

  private func scheduleLocalSitePreviewRefresh(generation: UInt64) {
    guard localSitePreviewRuntimeStatus.isRunning else { return }
    localSitePreviewRefreshTask?.cancel()
    localSitePreviewRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(350))
      } catch {
        return
      }
      guard let self,
            self.localSitePreviewGeneration == generation,
            self.localSitePreviewRuntimeStatus.isRunning else { return }
      self.localSitePreviewRefreshToken &+= 1
      self.localSitePreviewRuntimeStatus.message = "检测到仓库文件变更，预览已刷新。"
      self.publishActionMessage = self.localSitePreviewRuntimeStatus.message
      self.localSitePreviewRefreshTask = nil
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
    stopLocalSitePreviewFileWatcher()
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

}
