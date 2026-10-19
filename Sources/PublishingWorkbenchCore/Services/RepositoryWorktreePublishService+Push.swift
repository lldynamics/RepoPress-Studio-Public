import Foundation

extension RepositoryWorktreePublishService {
  private func reviewedHeadIsCurrent(_ sha: String, branch: String, root: URL) throws -> Bool {
    try output(["rev-parse", "HEAD"], root: root).trimmingCharacters(in: .whitespacesAndNewlines)
      == sha
      && output(["symbolic-ref", "--short", "HEAD"], root: root).trimmingCharacters(
        in: .whitespacesAndNewlines) == branch
      && output(["diff", "--cached", "--name-only", "HEAD", "--"], root: root).trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
  }

  func pushReviewedCommit(
    profile: SiteProfile, confirmation: RepositoryWorktreePublishConfirmation,
    commitSHA: String, root: URL, temporaryDirectory: URL, createdCommit: Bool
  ) throws -> RepositoryWorktreePublishResult {
    let execution = RepositoryWorktreeGitExecutionPolicyService(git: git)
    do {
      if createdCommit {
        try execution.postCommit(
          policy: confirmation.executionPolicy, root: root, commitSHA: commitSHA)
      }

      guard try reviewedHeadIsCurrent(commitSHA, branch: confirmation.snapshot.branch, root: root),
        try worktreeIsClean(root: root, pathScope: confirmation.pathScope)
      else {
        throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
          commitSHA: commitSHA,
          message: "提交后工作区或真实 index 发生变化，未执行推送。"
        )
      }
      let remoteBeforePush = try requiredRemoteSHA(branch: confirmation.snapshot.branch, root: root)
      guard remoteBeforePush == confirmation.snapshot.remoteBranchSHA else {
        throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
          commitSHA: commitSHA,
          message: "远端分支在提交期间发生变化，非强制推送已停止。"
        )
      }

      let pushOriginBeforePush = try validatedPushOrigin(profile: profile, root: root)
      guard pushOriginBeforePush == confirmation.snapshot.pushOriginURL else {
        throw RepositoryWorktreePublishError.snapshotDrift
      }
      let repositoryStatusBeforePush = try repositoryStatus(root: root)
      try execution.prePush(
        policy: confirmation.executionPolicy, branch: confirmation.snapshot.branch,
        root: root, commitSHA: commitSHA, remoteSHA: remoteBeforePush, origin: pushOriginBeforePush,
        temporaryDirectory: temporaryDirectory
      ) {
        guard
          try reviewedHeadIsCurrent(commitSHA, branch: confirmation.snapshot.branch, root: root),
          try worktreeIsClean(root: root, pathScope: confirmation.pathScope),
          try repositoryStatus(root: root) == repositoryStatusBeforePush,
          try validatedPushOrigin(profile: profile, root: root) == pushOriginBeforePush,
          try requiredRemoteSHA(branch: confirmation.snapshot.branch, root: root)
            == remoteBeforePush
        else { throw RepositoryGitExecutionPolicyError.reviewedContentChanged }
      }
      _ = try output(
        [
          "push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no", "origin",
          "\(commitSHA):refs/heads/\(confirmation.snapshot.branch)",
        ],
        root: root
      )
      let remoteAfterPush = try requiredRemoteSHA(
        branch: confirmation.snapshot.branch,
        root: root
      )
      guard remoteAfterPush.caseInsensitiveCompare(commitSHA) == .orderedSame else {
        throw RepositoryWorktreePublishError.gitFailed(
          command: "git ls-remote --heads origin",
          output: "远端提交与本地提交不一致。"
        )
      }
      return RepositoryWorktreePublishResult(
        commitSHA: commitSHA,
        branch: confirmation.snapshot.branch,
        pushed: true,
        remoteCommitSHA: remoteAfterPush,
        committedPaths: Array(
          Set(confirmation.snapshot.paths + (confirmation.snapshot.outgoingHistory?.paths ?? []))
        ).sorted()
      )
    } catch {
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: commitSHA,
        message: error.localizedDescription
      )
    }
  }
}
