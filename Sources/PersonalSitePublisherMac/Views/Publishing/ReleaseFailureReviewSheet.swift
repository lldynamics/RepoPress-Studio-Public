import PublishingWorkbenchCore
import SwiftUI

enum ReleaseFailureReviewContext {
  static func canReview(
    _ record: ReleaseRecord,
    profile: SiteProfile,
    drafts: [ArticleDraft],
    batchPlan: BatchPublishPlan? = nil
  )
    -> Bool
  {
    guard record.kind == .remotePublishFailure, record.siteProfileID == profile.id else {
      return false
    }
    if let target = record.targetBranch?.trimmedForPublishing.nilIfEmpty,
      target != (profile.branch.trimmedForPublishing.nilIfEmpty ?? "main")
    {
      return false
    }
    if let owner = record.repoOwner, owner != profile.repoOwner { return false }
    if let repository = record.repoName, repository != profile.repoName { return false }
    if let provider = record.repositoryProvider, provider != profile.repositoryProvider {
      return false
    }
    if let baseURL = record.repositoryBaseURL, baseURL != profile.repositoryBaseURL { return false }
    if !record.batchItems.isEmpty {
      return batchScopeMatches(record, profile: profile, drafts: drafts, batchPlan: batchPlan)
    }
    guard let draftID = record.draftID else { return true }
    return drafts.contains { $0.id == draftID && $0.belongs(toSiteProfileID: profile.id) }
  }

  static func batchScopeMatches(
    _ record: ReleaseRecord,
    profile: SiteProfile,
    drafts: [ArticleDraft],
    batchPlan: BatchPublishPlan?
  ) -> Bool {
    guard !record.batchItems.isEmpty,
      let batchPlan,
      batchPlan.profileID == profile.id
    else { return false }

    let historicalDraftIDs = Set(record.batchItems.map(\.draftID))
    let currentDraftIDs = Set(batchPlan.remotePublishableItems.map(\.draftID))
    guard historicalDraftIDs == currentDraftIDs else { return false }

    return historicalDraftIDs.allSatisfy { draftID in
      drafts.contains { $0.id == draftID && $0.belongs(toSiteProfileID: profile.id) }
    }
  }
}

/// Keeps the failed record visible and points back to the two publish
/// actions. Nothing is published from here; every retry is reviewed again.
struct ReleaseFailureReviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.publishCommandAction) private var publishCommandAction
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @ObservedObject private var history: WorkbenchReleaseHistoryObservationFacade
  let store: WorkbenchStore
  let record: ReleaseRecord

  init(store: WorkbenchStore, record: ReleaseRecord) {
    self.store = store
    self.record = record
    _publishing = ObservedObject(wrappedValue: store.publishing)
    _history = ObservedObject(wrappedValue: store.releaseHistoryObservation)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("重新审阅发布")
          .font(.workbenchHeadline)
        Text(record.title)
          .font(.workbenchBody)
          .textSelection(.enabled)
        if let branch = record.branchName {
          Text("原分支：\(branch)")
            .font(.workbenchMetadata)
        }
        if let target = record.targetBranch {
          Text("原目标分支：\(target)")
            .font(.workbenchMetadata)
        }
        Text("重新发布会再次打开确认页，核对全部文件和目标分支；不会自动重试。")
          .font(.workbenchBody)
          .foregroundStyle(.workbenchSecondary)
      }
      .padding(WorkbenchSpacing.content)
      Divider()
      if canContinueReview {
        HStack(spacing: WorkbenchSpacing.control) {
          if let draftID = record.draftID {
            Button("打开这篇文章") {
              _ = store.focusDraft(draftID, section: .writing)
              dismiss()
            }
            .help("回到写作页后，用“发布这篇”重新发布")
          }
          Button("发布全部…") {
            dismiss()
            publishCommandAction?.publishAll()
          }
          .disabled(publishCommandAction?.canPublishAll != true)
          Spacer()
          Button("关闭") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        .padding(WorkbenchSpacing.content)
      } else {
        ContentUnavailableView(
          "发布上下文已变化",
          systemImage: "exclamationmark.triangle",
          description: Text("原记录、站点或文章已变化，请关闭后重新核对。")
        )
        Button("关闭") { dismiss() }
          .padding(WorkbenchSpacing.content)
      }
    }
    .frame(minWidth: 520, idealWidth: 600)
    .accessibilityIdentifier("release-failure-review-sheet")
  }

  private var canContinueReview: Bool {
    guard store.activeProfileReleaseRecords.contains(where: { $0.id == record.id }),
      ReleaseFailureReviewContext.canReview(
        record,
        profile: publishing.activeProfile,
        drafts: publishing.drafts,
        batchPlan: publishing.batchPublishPlan
      )
    else { return false }
    return !record.batchItems.isEmpty || record.draftID == nil
      || publishing.selectedDraftID == record.draftID
  }
}
