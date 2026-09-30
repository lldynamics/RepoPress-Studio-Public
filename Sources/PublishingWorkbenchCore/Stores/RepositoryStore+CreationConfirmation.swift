extension RepositoryStore {
  @discardableResult
  public func createRemoteRepositoryForActiveProfile(
    privateRepository: Bool = true,
    expectedTarget: SiteOperationConfirmationTarget? = nil,
    store: WorkbenchStore
  ) async -> RemoteRepositoryCreationResult? {
    let target = expectedTarget ?? SiteOperationConfirmationTarget(profile: store.activeProfile)
    guard !Task.isCancelled, target.matches(store.activeProfile) else {
      store.setPublishActionMessage(
        CoreL10n.text("站点或仓库配置已变化，请重新确认创建仓库。"), status: .warning)
      return nil
    }
    let profile = target.profile
    guard !store.isRemoteRepositoryPublishing else {
      store.setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginRemoteRepositoryCheck(profile: profile, store: store) else {
      store.setPublishActionMessage(
        CoreL10n.text("已有仓库权限检查或建仓任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    defer { finishRemoteRepositoryCheck(operation) }
    do {
      let token = try repositoryAccessToken(for: profile)
      let result = try await remoteRepositoryPublishService.createRepository(
        profile: profile,
        token: token,
        privateRepository: privateRepository
      )
      guard remoteRepositoryCheckIsCurrent(operation, store: store),
        !Task.isCancelled, target.matches(store.activeProfile)
      else { return nil }
      remoteRepositoryCreationResult = result
      repositoryTokenAvailability = try repositoryTokenAvailability(for: profile)
      store.setPublishActionMessage(
        CoreL10n.format("%@ 仓库已创建：%@。", result.provider.displayName, result.repositoryName),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard remoteRepositoryCheckIsCurrent(operation, store: store),
        !Task.isCancelled, target.matches(store.activeProfile)
      else { return nil }
      store.setPublishActionMessage(
        CoreL10n.format("远端仓库创建失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }
}
