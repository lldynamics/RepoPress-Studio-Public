import Foundation

extension PublishingStore {
  @discardableResult
  public func rollbackRemoteRelease(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) async -> RemoteRepositoryRollbackResult? {

    let profile: SiteProfile
    let draft: RemoteRepositoryRollbackDraft
    do {
      draft = try RemoteRepositoryRollbackDraft.make(record: record)
      guard let profileID = record.siteProfileID,
        let recordedProfile = profiles.first(where: { $0.id == profileID })
      else { throw RemoteRepositoryRollbackSafetyError.missingRecordedProfile }
      try draft.validateRepositoryIdentity(profile: recordedProfile)
      profile = recordedProfile
    } catch {
      setPublishingActionMessage(
        CoreL10n.format("线上回滚不可用：%@", error.localizedDescription),
        status: .warning
      )
      return nil
    }

    guard remoteRepositoryMutationContext == nil else {
      setPublishingActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }

    let token: String?
    do {
      token = try repositoryAccessToken(for: profile)
    } catch {
      setPublishingActionMessage(
        CoreL10n.format("线上回滚失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
    guard token != nil else {
      setPublishingActionMessage(
        CoreL10n.text("仓库访问 Token 未保存，无法执行线上回滚。"),
        status: .warning
      )
      return nil
    }

    guard let operation = beginRemoteRepositoryMutation(profile: profile, store: store) else {
      setPublishingActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    setPublishingActionMessage(
      CoreL10n.format(
        "正在通过 %@ 回滚 %@…",
        profile.repositoryProvider.displayName,
        String(draft.commitSHA.prefix(8))
      ),
      status: .inProgress
    )
    defer { finishRemoteRepositoryMutation(operation, store: store) }

    do {
      let result = try await remoteRepositoryPublishService.rollback(
        draft: draft,
        profile: profile,
        token: token
      )
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      store.setRemoteRepositoryRollbackResult(result)
      store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
      let rollbackRecord = ReleaseRecord.remoteRollback(
        original: record, profile: profile, result: result)
      prependReleaseRecord(rollbackRecord)
      setPublishingActionMessage(
        CoreL10n.format("线上回滚完成：%@", result.shortRollbackCommitSHA),
        status: .success
      )
      if store.shouldRefreshDeploymentStatusAfterRemoteOperation(rollbackRecord) {
        await store.refreshDeploymentStatus(for: rollbackRecord, updatesMessage: false)
        guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      }
      store.save()
      return result
    } catch {
      guard remoteRepositoryMutationIsCurrent(operation, store: store) else { return nil }
      setPublishingActionMessage(
        CoreL10n.format("线上回滚失败：%@", error.localizedDescription),
        status: .failure
      )
      store.save()
      return nil
    }
  }
}
