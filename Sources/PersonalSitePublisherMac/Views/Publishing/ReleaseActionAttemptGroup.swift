import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// A visual timeline, not deduplication or proof that earlier attempts are
/// resolved. Every action keeps its original record identity and controls.
struct ReleaseActionAttemptGroup: Identifiable {
  let latest: ReleaseLedgerActionItem
  let previous: [ReleaseLedgerActionItem]
  var id: String { latest.id }

  private struct Key: Hashable {
    let draftID: UUID
    let path: String
    let target: ArticlePublishTrackingRequest.Target
  }

  static func make(ledger: ReleaseLedger) -> [Self] {
    let records = Dictionary(
      ledger.entries.map { ($0.id, $0.record) }, uniquingKeysWith: { first, _ in first })
    var groups: [[ReleaseLedgerActionItem]] = []
    var indexes: [Key: Int] = [:]
    for item in ledger.actionItems {
      guard let record = records[item.recordID], let key = key(record: record, action: item) else {
        groups.append([item])
        continue
      }
      if let index = indexes[key] {
        groups[index].append(item)
      } else {
        indexes[key] = groups.count
        groups.append([item])
      }
    }
    return groups.compactMap { items -> Self? in
      let ordered = items.enumerated().sorted {
        $0.element.createdAt == $1.element.createdAt
          ? $0.offset < $1.offset : $0.element.createdAt > $1.element.createdAt
      }.map(\.element)
      guard let latest = ordered.first else { return nil }
      return Self(latest: latest, previous: Array(ordered.dropFirst()))
    }.enumerated().sorted {
      let left = $0.element.latest
      let right = $1.element.latest
      if left.priority != right.priority { return left.priority.rawValue < right.priority.rawValue }
      if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
      return $0.offset < $1.offset
    }.map(\.element)
  }

  private static func key(record: ReleaseRecord, action: ReleaseLedgerActionItem) -> Key? {
    guard
      [.failedRelease, .retryDeploymentCheck, .observeDeployment, .keepRollbackReady]
        .contains(action.kind),
      record.kind == .remoteDirectCommit, record.batchItems.isEmpty,
      record.reviewURL == nil, record.reviewNumber == nil, record.reviewStatus == nil,
      let draftID = record.draftID, let path = record.markdownPath, !path.isEmpty,
      Set(record.changedPaths) == [path],
      record.sourceDocumentDigest?.isEmpty == false, record.commitSHA?.isEmpty == false,
      let target = record.articlePublishTrackingRequest?.target,
      target.profileID == record.siteProfileID,
      record.repositoryProvider == target.repository.provider,
      record.repositoryBaseURL == target.repository.baseURL,
      record.repoOwner == target.repository.owner, !target.repository.owner.isEmpty,
      record.repoName == target.repository.repository, !target.repository.repository.isEmpty,
      !target.repository.baseURL.isEmpty, !target.repository.branch.isEmpty,
      record.branchName == target.repository.branch, record.targetBranch == record.branchName
    else { return nil }
    return Key(draftID: draftID, path: path, target: target)
  }
}

struct ReleaseActionAttemptGroupView<Row: View>: View {
  let group: ReleaseActionAttemptGroup
  @ViewBuilder let row: (ReleaseLedgerActionItem) -> Row
  @State private var showsPrevious = false

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      row(group.latest)
      if !group.previous.isEmpty {
        DisclosureGroup(isExpanded: $showsPrevious) {
          Text("这些是同一文章的此前发布尝试，可能对应不同版本；展开可查看各自结果和恢复操作。")
            .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
          ForEach(group.previous) { item in row(item) }
        } label: {
          Text(String(format: String(localized: "此前尝试 · %d 项"), group.previous.count))
            .font(.workbenchBody.weight(.medium))
        }
        .disclosureGroupStyle(
          WorkbenchDisclosureGroupStyle(toggleIdentifier: "release-action-previous-\(group.id)"))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-action-attempt-group-\(group.id)")
  }
}
