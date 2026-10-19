import PublishingWorkbenchCore

enum RepositoryWorktreePublishConfirmationPresentationPolicy {
  static func warningIssues(from issues: [PreflightIssue]) -> [PreflightIssue] {
    issues.filter { PublishCheckClassification.classify($0) == .warning }
  }

  static func optionalIssues(from issues: [PreflightIssue]) -> [PreflightIssue] {
    issues.filter { PublishCheckClassification.classify($0) == .optionalOptimization }
  }

  static func isFailed(_ result: RepositoryPublishPreflightResult?) -> Bool {
    guard let result else { return false }
    if case .failed = result.outcome { return true }
    return false
  }

  static func isSkipped(_ result: RepositoryPublishPreflightResult?) -> Bool {
    guard let result else { return false }
    if case .skipped = result.outcome { return true }
    return false
  }

  static func requiresAcknowledgement(
    safetyWarningCount: Int,
    articleWarningCount: Int,
    sitePreflight: RepositoryPublishPreflightResult?
  ) -> Bool {
    safetyWarningCount > 0 || articleWarningCount > 0 || isFailed(sitePreflight)
  }

  static func canConfirm(
    isPublishing: Bool,
    isReviewComplete: Bool,
    requiresAcknowledgement: Bool,
    acknowledgementGiven: Bool,
    historyReviewComplete: Bool = true,
    historyAcknowledgementGiven: Bool = true,
    hasBlockingIssue: Bool = false
  ) -> Bool {
    !hasBlockingIssue && !isPublishing && isReviewComplete && historyReviewComplete
      && historyAcknowledgementGiven
      && (!requiresAcknowledgement || acknowledgementGiven)
  }
}
