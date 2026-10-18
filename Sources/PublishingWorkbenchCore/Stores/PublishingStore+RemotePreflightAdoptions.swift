import Foundation

extension PublishingStore {
  func packageApplyingRemotePublishPreflight(
    _ preflight: RemoteRepositoryPublishPreflightResult,
    to package: PublishPackage
  ) -> PublishPackage {
    var reconciled = package
    for index in reconciled.files.indices {
      let path = reconciled.files[index].repositoryPath.normalizedRelativePath()
      if let remoteVersion = preflight.remoteVersionsByPath[path]?.trimmedForPublishing.nilIfEmpty {
        reconciled.files[index].expectedRemoteSHA = remoteVersion
      }
    }
    return reconciled
  }

  @discardableResult
  func confirmDirectRemotePublishPreflightAdoptions(
    packages: [PublishPackage],
    preflight: RemoteRepositoryPublishPreflightResult,
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> Int {
    let adoptedPaths = Set(preflight.automaticallyAdoptedPaths.map { $0.normalizedRelativePath() })
    guard !adoptedPaths.isEmpty else { return 0 }
    let packagesByDraftID = Dictionary(uniqueKeysWithValues: packages.map { ($0.draftID, $0) })
    var changedDraftIDs = Set<UUID>()

    drafts = drafts.map { draft in
      guard let package = packagesByDraftID[draft.id] else { return draft }
      var updated = draft

      updated.attachments = updated.attachments.map { attachment in
        let path = attachment.repositoryPath.normalizedRelativePath()
        guard adoptedPaths.contains(path),
          let remoteVersion = preflight.remoteVersionsByPath[path]?.trimmedForPublishing.nilIfEmpty,
          attachment.repositorySHA?.trimmedForPublishing != remoteVersion
        else {
          return attachment
        }
        var confirmed = attachment
        confirmed.repositorySHA = remoteVersion
        changedDraftIDs.insert(draft.id)
        return confirmed
      }

      let markdownPath = package.markdownPath.normalizedRelativePath()
      if adoptedPaths.contains(markdownPath),
        let remoteVersion = preflight.remoteVersionsByPath[markdownPath]?.trimmedForPublishing
          .nilIfEmpty,
        let publishedContent = package.markdownFile?.content,
        let currentContent = publishPackageBuilder.build(draft: draft, profile: profile)
          .markdownFile?.content,
        currentContent == publishedContent
      {
        updated.confirmRepositoryBinding(
          profile: profile,
          repositoryPath: markdownPath,
          remoteRevision: remoteVersion,
          renderedContentDigest: ArticleDraft.repositoryDocumentDigest(publishedContent)
        )
        changedDraftIDs.insert(draft.id)
      }
      if updated != draft {
        updated.markUpdated(at: draft.updatedAt, replacing: draft)
      }
      return updated
    }

    for draftID in changedDraftIDs {
      removeDraftPublishPreviewSnapshot(for: draftID)
    }
    return adoptedPaths.count
  }
}
