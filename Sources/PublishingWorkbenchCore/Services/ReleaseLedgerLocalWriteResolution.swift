import Foundation

/// Keeps the historical write event while retiring its superseded action.
/// Missing identity/version evidence is deliberately not treated as success.
enum ReleaseLedgerLocalWriteResolution {
  static func resolvedIDs(in records: [ReleaseRecord]) -> Set<UUID> {
    let pushes = records.filter {
      $0.kind == .remoteDirectCommit && $0.commitSHA?.isEmpty == false
        && $0.articlePublishTrackingRequest != nil
    }
    return Set(
      records.filter { local in
        guard local.kind == .localWrite, let profileID = local.siteProfileID,
          let draftID = local.draftID, let path = local.markdownPath, !path.isEmpty,
          let digest = local.sourceDocumentDigest, !digest.isEmpty,
          let branch = local.branchName, !branch.isEmpty,
          let provider = local.repositoryProvider, let baseURL = local.repositoryBaseURL,
          let owner = local.repoOwner, !owner.isEmpty,
          let repository = local.repoName, !repository.isEmpty,
          !local.changedPaths.isEmpty, local.changedPaths.contains(path)
        else { return false }
        return pushes.contains { push in
          guard let request = push.articlePublishTrackingRequest,
            let cutoff = push.localWriteResolutionCutoff
          else { return false }
          return local.createdAt <= cutoff
            && cutoff <= push.createdAt
            && request.target.profileID == profileID
            && request.target.repository
              == DraftRepositoryIdentity(
                provider: provider, baseURL: baseURL,
                owner: owner, repository: repository, branch: branch)
            && push.siteProfileID == profileID && push.draftID == draftID
            && push.markdownPath == path && push.sourceDocumentDigest == digest
            && push.branchName == branch && push.targetBranch == branch
            && push.repositoryProvider == local.repositoryProvider
            && push.repositoryBaseURL == local.repositoryBaseURL
            && push.repoOwner == local.repoOwner && push.repoName == local.repoName
            && Set(local.changedPaths).isSubset(of: Set(push.changedPaths))
        }
      }.map(\.id))
  }
}
