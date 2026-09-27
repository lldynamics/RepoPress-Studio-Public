import PublishingWorkbenchCore
import SwiftUI

struct ReleaseArticleVerificationRows: View {
  let store: WorkbenchStore
  let record: ReleaseRecord
  let snapshot: DeploymentStatusSnapshot?
  @State private var checkingDraftID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(record.articleVerificationTargets) { target in
        let result = snapshot?.articleResults?.first(where: { $0.target == target })
        let articleURL =
          ([target.publicURLText].compactMap { $0 }
          + (result?.signals.compactMap(\.urlText) ?? []))
          .compactMap(URL.init(string:))
          .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
        VStack(alignment: .leading, spacing: 5) {
          Label(target.draftTitle, systemImage: (result?.level ?? .unknown).systemImage)
            .font(.callout.weight(.medium))
          if snapshot?.verifiesArticle(target, in: record) == true, let articleURL {
            HStack(spacing: 8) {
              Label("已上线", systemImage: "checkmark.seal.fill")
                .foregroundStyle(WorkbenchTheme.success)
              Button("打开文章") { ExternalURLOpener.open(articleURL) }
                .buttonStyle(.link)
                .accessibilityIdentifier("publish-article-live-link")
            }
          }
          Text(target.publicURLText ?? target.publicPath ?? target.markdownPath)
            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
          if target.publicPath == nil {
            Text("历史记录未保存公开路径，当前结果使用文件路径推导。")
              .font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Button(
              checkingDraftID == target.draftID
                ? String(localized: "正在检查…") : String(localized: "重新检查此文章")
            ) {
              checkingDraftID = target.draftID
              Task { @MainActor in
                _ = await store.refreshDeploymentStatus(for: record, articleDraftID: target.draftID)
                checkingDraftID = nil
              }
            }
            .disabled(
              checkingDraftID != nil || store.isDeploymentStatusChecking
                || !store.canCheckDeploymentStatus(for: record)
            )
            .help(store.deploymentStatusReadiness(for: record).nextStep)
            if let articleURL, snapshot?.verifiesArticle(target, in: record) != true {
              Button("打开文章页面") { ExternalURLOpener.open(articleURL) }.buttonStyle(.link)
            }
          }
          if let result {
            Text(
              result.verifiesSourceVersion
                ? String(localized: "正文版本已确认")
                : String(localized: "正文版本尚未确认")
            )
            .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("检查详情") {
              ForEach(result.signals) { signal in
                VStack(alignment: .leading, spacing: 3) {
                  Label(signal.title, systemImage: signal.level.systemImage)
                  Text(signal.message).font(.caption).foregroundStyle(.secondary).textSelection(
                    .enabled)
                }
              }
            }
          } else {
            Text("此文章尚未验证，请检查全部文章。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .contain)
      }
    }
  }
}

/// Binds the result card to the operation's record, never to an unrelated latest release.
enum PublishResultRecordSelection {
  static func recordID(
    result: RemoteRepositoryPublishResult?, records: [ReleaseRecord],
    previousRecordIDs: Set<UUID>, profileID: UUID, draftIDs: Set<UUID>
  ) -> UUID? {
    let matching = records.filter { record in
      guard record.siteProfileID == profileID else { return false }
      let ids = Set(record.batchItems.map(\.draftID) + [record.draftID].compactMap { $0 })
      return ids == draftIDs
    }
    if let id = result?.releaseRecordID, matching.contains(where: { $0.id == id }) { return id }
    let failures = matching.filter {
      !previousRecordIDs.contains($0.id) && $0.kind == .remotePublishFailure
    }
    return result == nil && failures.count == 1 ? failures[0].id : nil
  }
}
