import Foundation

extension WorkbenchStore {
  func setRepositoryAutoSyncState(_ state: RepositoryAutoSyncState) {
    setRepositoryAutoSyncState(state, for: activeProfileID)
  }

  func setRepositoryAutoSyncState(_ state: RepositoryAutoSyncState, for profileID: UUID) {
    repositoryStore.repositoryAutoSyncStateByProfileID[profileID] = state
    if profileID == activeProfileID {
      repositoryStore.repositoryAutoSyncState = state
    }
  }

  func setRemoteRepositoryPublishing(_ isPublishing: Bool) {
    repositoryStore.isRemoteRepositoryPublishing = isPublishing
  }

  func setRemoteRepositoryPublishProgress(_ progress: RemoteRepositoryPublishProgress?) {
    repositoryStore.remoteRepositoryPublishProgress = progress
  }

  func setRemoteRepositoryPublishResult(_ result: RemoteRepositoryPublishResult?) {
    repositoryStore.remoteRepositoryPublishResult = result
  }

  func setRemoteRepositoryRollbackResult(_ result: RemoteRepositoryRollbackResult?) {
    repositoryStore.remoteRepositoryRollbackResult = result
  }

  func setRemoteRepositoryReviewWithdrawalResult(_ result: RemoteRepositoryReviewWithdrawalResult?) {
    repositoryStore.remoteRepositoryReviewWithdrawalResult = result
  }

  func setRepositoryTokenAvailability(_ availability: KeychainTokenAvailability) {
    repositoryStore.repositoryTokenAvailability = availability
  }

  func setLocalGitPublishResult(_ result: LocalGitPublishResult?) {
    repositoryStore.localGitPublishResult = result
  }

  func setRemoteRepositoryAccessCheck(_ check: RemoteRepositoryAccessCheck?) {
    repositoryStore.setRemoteRepositoryAccessCheck(check, for: activeProfileID)
  }
}
