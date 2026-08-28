import Foundation
import PublishingGitCore

struct ReleaseLedgerGitProjection {
  func records(
    legacyRecords: [ReleaseRecord],
    history: RepositoryReleaseHistorySnapshot,
    profile: SiteProfile
  ) -> [ReleaseRecord] {
    guard history.historyAvailability == .available else {
      return legacyRecords
    }

    let commitsBySHA = Dictionary(
      uniqueKeysWithValues: history.commits.map { ($0.sha.lowercased(), $0) }
    )
    let notesBySHA = Dictionary(
      history.notes.map { ($0.commitSHA.lowercased(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let tagsBySHA = Dictionary(
      grouping: history.tags,
      by: { $0.targetSHA.lowercased() }
    )

    var representedSHAs: Set<String> = []
    var projected = legacyRecords.map { record in
      guard let sha = record.commitSHA?.trimmedForPublishing.nilIfEmpty?.lowercased(),
            let commit = commitsBySHA[sha] else {
        return record
      }
      representedSHAs.insert(sha)
      return reconciled(record: record, commit: commit, profile: profile)
    }

    var usedIDs = Set(projected.map(\.id))
    for commit in history.commits where !representedSHAs.contains(commit.sha.lowercased()) {
      let sha = commit.sha.lowercased()
      let note = notesBySHA[sha]
      let tags = (tagsBySHA[sha] ?? []).sorted { $0.name < $1.name }
      var record = gitRecord(commit: commit, tags: tags, note: note, profile: profile)
      if usedIDs.contains(record.id) {
        record.id = deterministicReleaseID(for: sha)
      }
      usedIDs.insert(record.id)
      projected.append(record)
    }

    return projected.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.createdAt > rhs.createdAt
    }
  }

  private func reconciled(
    record: ReleaseRecord,
    commit: RepositoryCommitInfo,
    profile: SiteProfile
  ) -> ReleaseRecord {
    var record = record
    record.commitSHA = commit.sha
    record.siteProfileID = record.siteProfileID ?? profile.id
    record.siteName = record.siteName ?? profile.name
    record.repositoryProvider = record.repositoryProvider ?? profile.repositoryProvider
    record.repositoryBaseURL = record.repositoryBaseURL ?? profile.repositoryBaseURL
    record.repoOwner = record.repoOwner ?? profile.repoOwner
    record.repoName = record.repoName ?? profile.repoName
    switch record.kind {
    case .directCommit, .remoteDirectCommit, .remoteRollback:
      record.createdAt = commit.date
    case .localWrite, .batchLocalWrite, .reviewBranch, .remotePreviewBranch, .remoteReviewRequest,
         .remotePublishFailure, .remoteReviewWithdrawal:
      break
    }
    return record
  }

  private func gitRecord(
    commit: RepositoryCommitInfo,
    tags: [RepositoryReleaseTag],
    note: RepositoryReleaseNote?,
    profile: SiteProfile
  ) -> ReleaseRecord {
    let metadata = note?.metadata ?? [:]
    let firstMessageLine = commit.message
      .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)
      ?? commit.message
    let kind = metadata["kind"].flatMap(ReleaseRecordKind.init(rawValue:)) ?? .directCommit
    let noteID = metadata["releaseID"].flatMap(UUID.init(uuidString:))
      ?? metadata["id"].flatMap(UUID.init(uuidString:))

    var summaryParts = [CoreL10n.format("Git · %@", commit.author)]
    if !tags.isEmpty {
      summaryParts.append(
        CoreL10n.format("标签：%@", tags.map(\.name).joined(separator: CoreL10n.text("、")))
      )
    }
    if let channel = metadata["channel"]?.trimmedForPublishing.nilIfEmpty {
      summaryParts.append(CoreL10n.format("渠道：%@", channel))
    }

    return ReleaseRecord(
      id: noteID ?? deterministicReleaseID(for: commit.sha),
      kind: kind,
      title: metadata["title"]?.trimmedForPublishing.nilIfEmpty ?? firstMessageLine,
      summary: metadata["summary"]?.trimmedForPublishing.nilIfEmpty
        ?? summaryParts.joined(separator: " · "),
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: metadata["draftID"].flatMap(UUID.init(uuidString:)),
      draftTitle: metadata["draftTitle"]?.trimmedForPublishing.nilIfEmpty,
      markdownPath: metadata["markdownPath"]?.trimmedForPublishing.nilIfEmpty,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: metadata["branchName"]?.trimmedForPublishing.nilIfEmpty,
      targetBranch: metadata["targetBranch"]?.trimmedForPublishing.nilIfEmpty
        ?? profile.branch.trimmedForPublishing.nilIfEmpty,
      commitSHA: commit.sha,
      reviewURL: metadata["reviewURL"]?.trimmedForPublishing.nilIfEmpty,
      reviewTitle: metadata["reviewTitle"]?.trimmedForPublishing.nilIfEmpty,
      createdAt: commit.date
    )
  }

  private func deterministicReleaseID(for sha: String) -> UUID {
    let hex = sha.lowercased().filter { $0.isHexDigit }
    let padded = String((hex + String(repeating: "0", count: 32)).prefix(32))
    let bytes = Array(padded.utf8)
    let first = String(decoding: bytes[0..<8], as: UTF8.self)
    let second = String(decoding: bytes[8..<12], as: UTF8.self)
    let third = String(decoding: bytes[12..<16], as: UTF8.self)
    let fourth = String(decoding: bytes[16..<20], as: UTF8.self)
    let fifth = String(decoding: bytes[20..<32], as: UTF8.self)
    let uuidText = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
    return UUID(uuidString: uuidText) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}
