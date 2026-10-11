import Foundation

enum PublishExecutionPersistenceOutcome: Equatable, Sendable {
  case saved
  case requiresLocalRecovery

  var recoveryMessage: String? {
    guard self == .requiresLocalRecovery else { return nil }
    return CoreL10n.text("远端已返回结果，本地记录保存失败。请保留当前窗口并重试保存。")
  }
}

struct RemotePublishCompletionOutcome: Sendable {
  let persistence: PublishExecutionPersistenceOutcome
  let remoteFeedback: PublishActionFeedback
  let remoteProgressMessage: String

  var feedback: PublishActionFeedback {
    guard let recoveryMessage = persistence.recoveryMessage else { return remoteFeedback }
    return PublishActionFeedback(
      message: [remoteFeedback.message, recoveryMessage].joined(separator: "\n"),
      status: remoteFeedback.status == .failure ? .failure : .warning,
      source: remoteFeedback.source
    )
  }

  var progressMessage: String {
    guard let recoveryMessage = persistence.recoveryMessage else { return remoteProgressMessage }
    return [remoteProgressMessage, recoveryMessage].joined(separator: "\n")
  }
}

extension PublishingStore {
  /// Both publishing paths persist the accepted remote result together with
  /// the frozen document lifecycle and sync changes, before reporting success.
  func recordAcceptedRemotePublish(
    result: RemoteRepositoryPublishResult,
    releaseRecord: ReleaseRecord,
    executionID: UUID,
    packages: [PublishPackage],
    profile: SiteProfile,
    deferDraftLifecycleMutation: Bool,
    store: WorkbenchStore
  ) -> PublishExecutionPersistenceOutcome {
    remoteRepositoryConflictSession = nil
    store.setRemoteRepositoryPublishResult(result)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    prependReleaseRecord(releaseRecord)
    if !deferDraftLifecycleMutation {
      confirmDirectRemotePublishLifecycle(packages: packages, profile: profile, result: result)
      if result.mode.createsReview {
        markRemotePublishReviewSuccess(packages: packages, profile: profile)
      }
    }
    if result.mode != .previewBranch {
      store.recordRemoteRepositoryPublishInAutoSync(result, profileID: profile.id)
    }
    return finishPublishExecution(executionID, record: releaseRecord, store: store)
  }

  func applyRemotePublishCompletion(
    mode: RemoteRepositoryPublishMode,
    operationSummary: String,
    deploymentStatus: DeploymentStatusSnapshot?,
    persistence: PublishExecutionPersistenceOutcome,
    store: WorkbenchStore
  ) {
    let outcome = RemotePublishCompletionOutcome(
      persistence: persistence,
      remoteFeedback: remotePublishCompletionFeedback(
        mode: mode, operationSummary: operationSummary, deploymentStatus: deploymentStatus),
      remoteProgressMessage: remotePublishCompletedProgressMessage(
        mode: mode, deploymentStatus: deploymentStatus)
    )
    let feedback = outcome.feedback
    setPublishingActionMessage(feedback.message, status: feedback.status)
    store.save()
    store.setRemoteRepositoryPublishProgress(
      .init(
        stage: .completed, progress: 1, message: outcome.progressMessage,
        detail: feedback.message)
    )
  }

  /// Conflict resolution defers local merge/review lifecycle until after the
  /// remote request. Its completion must save that final snapshot before
  /// choosing feedback, including a branch that retained newer local edits.
  func completeRemoteConflictResolution(
    message: String, status: PublishActionMessageStatus,
    result: RemoteRepositoryPublishResult? = nil, store: WorkbenchStore
  ) -> RemoteRepositoryConflictResolutionOutcome {
    let previousFailure =
      result == nil
      ? nil
      : publishActionFeedback.flatMap {
        $0.status == .failure ? $0 : nil
      }
    let persistence: PublishExecutionPersistenceOutcome
    if let result {
      persistence = persistRemoteConflictCompletion(result, store: store)
    } else {
      let saved = store.saveCurrentStateSynchronously() && !store.hasUnsavedChanges
      persistence = saved ? .saved : .requiresLocalRecovery
    }
    let outcome = RemotePublishCompletionOutcome(
      persistence: persistence,
      remoteFeedback: PublishActionFeedback(
        message: previousFailure.map { [message, $0.message].joined(separator: "\n") } ?? message,
        status: previousFailure == nil ? status : .failure,
        source: .publishing),
      remoteProgressMessage: message
    )
    setPublishingActionMessage(outcome.feedback.message, status: outcome.feedback.status)
    if result != nil {
      store.setRemoteRepositoryPublishProgress(
        .init(
          stage: .completed, progress: 1, message: outcome.progressMessage,
          detail: outcome.feedback.message)
      )
    }
    return .completed(message: outcome.feedback.message)
  }

  /// The inner publisher saved the remote result before the resolver applied
  /// its frozen local merge. Persist that final lifecycle in the same execution
  /// record, including a drift branch that must retain newer local edits.
  private func persistRemoteConflictCompletion(
    _ result: RemoteRepositoryPublishResult, store: WorkbenchStore
  ) -> PublishExecutionPersistenceOutcome {
    guard let releaseRecordID = result.releaseRecordID,
      let record = releaseRecords.first(where: { $0.id == releaseRecordID })
    else {
      _ = store.saveCurrentStateSynchronously()
      return .requiresLocalRecovery
    }
    let executionIDs = publishSession.executionRecords.filter {
      $0.releaseRecordID == releaseRecordID
    }.map(\.id)
    guard !executionIDs.isEmpty else {
      _ = store.saveCurrentStateSynchronously()
      return .requiresLocalRecovery
    }
    return finishPublishExecutions(executionIDs, record: record, store: store)
  }
}
