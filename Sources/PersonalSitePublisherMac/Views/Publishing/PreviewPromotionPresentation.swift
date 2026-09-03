import Foundation
import PublishingWorkbenchCore

enum PreviewPromotionRecordEligibility: Equatable {
  case eligible(PreviewPromotionEntryAction)
  case unavailable(PreviewPromotionUnavailableReason)
}

extension PreviewPromotionRecordEligibility {
  var isEligible: Bool {
    if case .eligible = self { return true }
    return false
  }
}

enum PreviewPromotionEntryAction: Equatable {
  case createReview
  case inspectAndMerge

  var title: String {
    switch self {
    case .createReview:
      return String(localized: "转为正式发布")
    case .inspectAndMerge:
      return String(localized: "检查并合并")
    }
  }
}

enum PreviewPromotionUnavailableReason: Equatable {
  case unsupportedProvider
  case missingArticle
  case batchRecord
  case alreadyMerged
  case unsupportedRecord
}

enum PreviewPromotionActionState: Equatable {
  case enabled
  case disabled(PreviewPromotionActionDisabledReason)

  var isEnabled: Bool {
    if case .enabled = self { return true }
    return false
  }
}

enum PreviewPromotionActionDisabledReason: Equatable {
  case unavailable(PreviewPromotionUnavailableReason)
  case protectedWorkbenchUnavailable
  case remoteOperationRunning
}

struct PreviewPromotionTaskContext: Equatable {
  let recordID: UUID
  let profileID: UUID
  let selectedDraftID: UUID?

  init(record: ReleaseRecord, profileID: UUID, selectedDraftID: UUID?) {
    self.recordID = record.id
    self.profileID = profileID
    self.selectedDraftID = selectedDraftID
  }
}

enum PreviewPromotionWorkflowState: Equatable {
  case idle
  case preparing
  case previewReady
  case creatingReview
  case checkingMerge
  case merging
  case completed

  var isLoading: Bool {
    switch self {
    case .preparing, .creatingReview, .checkingMerge, .merging:
      return true
    case .idle, .previewReady, .completed:
      return false
    }
  }
}

enum PreviewPromotionPresentation {
  static func offersGitHubTokenSettingsLink(
    for record: ReleaseRecord,
    profileRepositoryBaseURL: String? = nil
  ) -> Bool {
    let recordedBaseURL = record.repositoryBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
    return offersGitHubTokenSettingsLink(
      provider: record.repositoryProvider,
      repositoryBaseURL: recordedBaseURL?.isEmpty == false
        ? recordedBaseURL : profileRepositoryBaseURL
    )
  }

  static func offersGitHubTokenSettingsLink(
    provider: RepositoryProvider?,
    repositoryBaseURL: String?
  ) -> Bool {
    guard provider == .github else { return false }
    let resolvedBaseURL =
      [repositoryBaseURL]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty })
      ?? RepositoryProvider.github.defaultBaseURL
    return URL(string: resolvedBaseURL)?
      .host?.lowercased() == "api.github.com"
  }

  static func eligibility(for record: ReleaseRecord) -> PreviewPromotionRecordEligibility {
    guard record.repositoryProvider == .github else { return .unavailable(.unsupportedProvider) }
    guard record.markdownPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      return .unavailable(.missingArticle)
    }
    guard record.batchItems.isEmpty else { return .unavailable(.batchRecord) }

    switch record.kind {
    case .remotePreviewBranch:
      return .eligible(.createReview)
    case .remoteReviewRequest:
      if record.reviewStatus?.state == .merged {
        return .unavailable(.alreadyMerged)
      }
      return .eligible(.inspectAndMerge)
    case .localWrite, .batchLocalWrite, .directCommit, .reviewBranch, .remoteDirectCommit,
      .remotePublishFailure, .remoteRollback, .remoteReviewWithdrawal:
      return .unavailable(.unsupportedRecord)
    }
  }

  static func actionState(
    for record: ReleaseRecord,
    canUseProtectedWorkbench: Bool,
    isRemoteRepositoryPublishing: Bool
  ) -> PreviewPromotionActionState {
    switch eligibility(for: record) {
    case .unavailable(let reason):
      return .disabled(.unavailable(reason))
    case .eligible:
      if !canUseProtectedWorkbench { return .disabled(.protectedWorkbenchUnavailable) }
      if isRemoteRepositoryPublishing { return .disabled(.remoteOperationRunning) }
      return .enabled
    }
  }

  static func acceptsCompletion(
    _ context: PreviewPromotionTaskContext,
    activeProfileID: UUID,
    selectedDraftID: UUID?,
    canUseProtectedWorkbench: Bool
  ) -> Bool {
    context.profileID == activeProfileID
      && context.selectedDraftID == selectedDraftID
      && canUseProtectedWorkbench
  }

  static func completionMessage(for record: ReleaseRecord, mergedCommitSHA: String?) -> String {
    let commit = mergedCommitSHA ?? record.reviewStatus?.mergeCommitSHA
    if let commit, !commit.isEmpty {
      return String(
        format: String(localized: "已合并提交 %@，部署待验证，尚未确认上线。"),
        String(commit.prefix(8))
      )
    }
    return String(localized: "已合并到正式分支，部署待验证，尚未确认上线。")
  }
}
