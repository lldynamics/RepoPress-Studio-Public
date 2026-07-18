import PublishingWorkbenchCore

extension EditorDisplayMode {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .edit:
      return "display.editor-display-mode.edit"
    case .preview:
      return "display.editor-display-mode.preview"
    case .split:
      return "display.editor-display-mode.split"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension DraftStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .draft:
      return "display.draft-status.draft"
    case .ready:
      return "display.draft-status.ready"
    case .published:
      return "display.draft-status.published"
    case .failed:
      return "display.draft-status.failed"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ArticleVisibility {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .public:
      return "display.article-visibility.public"
    case .private:
      return "display.article-visibility.private"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension PreflightSeverity {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .error:
      return "display.preflight-severity.error"
    case .warning:
      return "display.preflight-severity.warning"
    case .info:
      return "display.preflight-severity.info"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension LocalPublishActionReadiness {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ready:
      return "display.local-publish-action-readiness.ready"
    case .needsReview:
      return "display.local-publish-action-readiness.needs-review"
    case .blocked:
      return "display.local-publish-action-readiness.blocked"
    case .unchanged:
      return "display.local-publish-action-readiness.unchanged"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension PublishFileDiffStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .added:
      return "display.publish-file-diff-status.added"
    case .modified:
      return "display.publish-file-diff-status.modified"
    case .deleted:
      return "display.publish-file-diff-status.deleted"
    case .unchanged:
      return "display.publish-file-diff-status.unchanged"
    case .missingSource:
      return "display.publish-file-diff-status.missing-source"
    case .unsafePath:
      return "display.publish-file-diff-status.unsafe-path"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension PublishFileKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .markdown:
      return "display.publish-file-kind.markdown"
    case .image:
      return "display.publish-file-kind.image"
    case .video:
      return "display.publish-file-kind.video"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension PublishFileOperation {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .upsert:
      return "display.publish-file-operation.upsert"
    case .delete:
      return "display.publish-file-operation.delete"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension DraftVersionReason {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .automatic:
      return "display.draft-version-reason.automatic"
    case .manual:
      return "display.draft-version-reason.manual"
    case .beforeRestore:
      return "display.draft-version-reason.before-restore"
    case .beforeDeletion:
      return "display.draft-version-reason.before-deletion"
    case .beforeBatchProcessing:
      return "display.draft-version-reason.before-batch-processing"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension DraftRepositoryCleanupStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .pending:
      return "display.draft-repository-cleanup-status.pending"
    case .completed:
      return "display.draft-repository-cleanup-status.completed"
    case .kept:
      return "display.draft-repository-cleanup-status.kept"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension RemoteRepositoryPublishMode {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .directCommit:
      return "display.remote-repository-publish-mode.direct-commit"
    case .reviewRequest:
      return "display.remote-repository-publish-mode.review-request"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension DeploymentStatusLevel {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .success:
      return "display.deployment-status-level.success"
    case .running:
      return "display.deployment-status-level.running"
    case .failed:
      return "display.deployment-status-level.failed"
    case .unknown:
      return "display.deployment-status-level.unknown"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ReleaseRecordKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .localWrite:
      return "display.release-record-kind.local-write"
    case .batchLocalWrite:
      return "display.release-record-kind.batch-local-write"
    case .directCommit:
      return "display.release-record-kind.direct-commit"
    case .reviewBranch:
      return "display.release-record-kind.review-branch"
    case .remoteDirectCommit:
      return "display.release-record-kind.remote-direct-commit"
    case .remoteReviewRequest:
      return "display.release-record-kind.remote-review-request"
    case .remotePublishFailure:
      return "display.release-record-kind.remote-publish-failure"
    case .remoteRollback:
      return "display.release-record-kind.remote-rollback"
    case .remoteReviewWithdrawal:
      return "display.release-record-kind.remote-review-withdrawal"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ReleaseLedgerStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .localOnly:
      return "display.release-ledger-status.local-only"
    case .pendingReview:
      return "display.release-ledger-status.pending-review"
    case .pendingDeployment:
      return "display.release-ledger-status.pending-deployment"
    case .pendingRemoteRecovery:
      return "display.release-ledger-status.pending-remote-recovery"
    case .pendingRetry:
      return "display.release-ledger-status.pending-retry"
    case .deploying:
      return "display.release-ledger-status.deploying"
    case .succeeded:
      return "display.release-ledger-status.succeeded"
    case .failed:
      return "display.release-ledger-status.failed"
    case .unknown:
      return "display.release-ledger-status.unknown"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ReleaseLedgerActionPriority {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .high:
      return "display.release-ledger-action-priority.high"
    case .medium:
      return "display.release-ledger-action-priority.medium"
    case .low:
      return "display.release-ledger-action-priority.low"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ReleaseLedgerActionKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .failedRelease:
      return "display.release-ledger-action-kind.failed-release"
    case .retryDeploymentCheck:
      return "display.release-ledger-action-kind.retry-deployment-check"
    case .observeDeployment:
      return "display.release-ledger-action-kind.observe-deployment"
    case .completeReview:
      return "display.release-ledger-action-kind.complete-review"
    case .publishLocalChanges:
      return "display.release-ledger-action-kind.publish-local-changes"
    case .recoverPartialRemotePublish:
      return "display.release-ledger-action-kind.recover-partial-remote-publish"
    case .keepRollbackReady:
      return "display.release-ledger-action-kind.keep-rollback-ready"
    }
  }

  var fallbackDisplayName: String { displayName }
}
