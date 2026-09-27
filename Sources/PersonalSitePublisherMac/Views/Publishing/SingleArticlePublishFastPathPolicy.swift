import Foundation
import PublishingWorkbenchCore

/// The workspace can skip the drawer only when its freshly prepared review is
/// unambiguous. The confirmation sheet and its frozen expectation are still
/// required before any remote write.
enum SingleArticlePublishFastPathPolicy {
  static func qualifies(
    _ snapshot: DraftPublishPreviewSnapshot,
    draftID: UUID,
    profileID: UUID
  ) -> Bool {
    let package = snapshot.publishPackage
    let preview = snapshot.remotePublishPreview
    let readiness = snapshot.localPublishReadiness
    guard snapshot.context.draftID == draftID,
      snapshot.context.profileID == profileID,
      package.draftID == draftID,
      package.markdownFile != nil,
      preview.readiness == .ready,
      preview.canPublish,
      preview.blockingIssues.isEmpty,
      preview.warningIssues.isEmpty,
      readiness.writeReadiness == .ready,
      readiness.commitReadiness == .ready,
      readiness.writeBlockingIssues.isEmpty,
      readiness.commitBlockingIssues.isEmpty,
      readiness.warningIssues.isEmpty,
      preview.remoteConflictPaths.isEmpty,
      !preview.changedPaths.isEmpty
    else { return false }

    let changedPaths = Set(preview.changedPaths)
    let packagePaths = Set(package.files.map(\.repositoryPath))
    return changedPaths.count == preview.changedPaths.count
      && !packagePaths.isEmpty
      && changedPaths.isSubset(of: packagePaths)
  }
}
