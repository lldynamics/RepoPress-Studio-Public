import PublishingWorkbenchCore
import SwiftUI

struct DraftUnpublishReviewView: View {
  let target: ArticleDraft
  let profile: SiteProfile
  let displayTitle: (UUID, String) -> String
  let isMasked: (UUID) -> Bool
  let loadSnapshot: @MainActor () async throws -> SiteUnpublishImpactSnapshot
  let onOpenSource: (UUID) -> Void
  let onConfirm: (SiteUnpublishImpactSnapshot) async -> Bool
  let onCancel: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var snapshot: SiteUnpublishImpactSnapshot?
  @State private var isLoading = true
  @State private var message: String?
  @State private var isConfirming = false
  @State private var isClosed = false
  @State private var loadID = UUID()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("下线前检查引用影响")
        .font(.title2.weight(.semibold))
      Text("统计当前站点已纳入工作台的文章，包括未发布文章；不包含回收站、其他站点和自身引用，也不扫描外部网站。")
        .foregroundStyle(.secondary)
      let currentProfile = snapshot?.profileSnapshot ?? profile
      let currentTarget = snapshot?.targetDraft ?? target
      let strategy =
        currentProfile.repositoryPublishStrategy == .direct
        ? String(localized: "直接提交远端删除")
        : String(localized: "创建下线 PR/MR")
      let title = displayTitle(currentTarget.id, String(localized: "未命名文章"))
      Text("仍然下线会把「\(title)」移到回收站、\(strategy)，并清理本地 Markdown；图片资源不会自动删除。失败项会保留在发布抽屉中重试。")
        .font(.callout)
        .foregroundStyle(.secondary)

      if isLoading {
        ProgressView("正在扫描文章引用…")
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let snapshot {
        impactContent(snapshot)
      }
      if let message {
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("unpublish-impact-message")
      }
      HStack {
        Button("取消", role: .cancel) { close() }
          .keyboardShortcut(.cancelAction)
          .disabled(isConfirming)
          .accessibilityIdentifier("unpublish-impact-cancel")
        Spacer()
        Button("仍然下线", role: .destructive) { confirm() }
          .disabled(isLoading || snapshot == nil || isConfirming)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("unpublish-impact-confirm")
      }
    }
    .padding(24)
    .frame(width: 620)
    .accessibilityIdentifier("unpublish-impact-review")
    .task { await load() }
    .onDisappear { isClosed = true }
  }

  @ViewBuilder
  private func impactContent(_ snapshot: SiteUnpublishImpactSnapshot) -> some View {
    if snapshot.referenceCount == 0 {
      Label("在检查范围内未发现指向这篇文章的链接。", systemImage: "checkmark.circle")
    } else {
      Text("\(snapshot.sourceArticleCount) 篇文章，\(snapshot.referenceCount) 处引用")
        .font(.headline)
      Text("点击来源文章处理引用，本次下线操作会取消。")
        .font(.callout)
        .foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(snapshot.sources) { source in
            Button {
              onOpenSource(source.sourceDraftID)
              close()
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(source.sourceDraftID, String(localized: "未命名文章")))
                  .font(.body.weight(.medium))
                if isMasked(source.sourceDraftID) {
                  Text("引用详情已隐藏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                  Text(
                    "\(source.anchorText.nilIfEmpty ?? source.target) · \(source.sourceURL ?? "")"
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isConfirming)
            .help("打开文章处理引用")
            .accessibilityIdentifier("unpublish-impact-source-\(source.id)")
          }
        }
      }
      .frame(maxHeight: 300)
    }
  }

  private func load() async {
    let requestID = UUID()
    loadID = requestID
    isLoading = true
    snapshot = nil
    message = nil
    do {
      let result = try await loadSnapshot()
      guard !Task.isCancelled, !isClosed, loadID == requestID else { return }
      snapshot = result
      isLoading = false
    } catch {
      guard !Task.isCancelled, !isClosed, loadID == requestID else { return }
      isLoading = false
      message = error.localizedDescription
    }
  }

  private func confirm() {
    guard let snapshot, !isLoading, !isConfirming else { return }
    isConfirming = true
    Task {
      guard !isClosed, !Task.isCancelled else {
        isConfirming = false
        return
      }
      if await onConfirm(snapshot) {
        // The parent closes this sheet when handing the accepted action to
        // publishing. A later completion must not dismiss a newer sheet.
        if !isClosed { close() }
      } else if !isClosed {
        await load()
        if self.snapshot != nil {
          message = String(localized: "文章或引用内容已变化，预览已更新；请重新确认。")
        }
      }
      isConfirming = false
    }
  }

  private func close() {
    isClosed = true
    onCancel()
    dismiss()
  }
}
