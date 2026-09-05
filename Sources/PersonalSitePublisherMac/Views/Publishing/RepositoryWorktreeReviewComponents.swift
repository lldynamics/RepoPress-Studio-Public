import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorktreeReviewFileList: View {
  let entries: [RepositoryWorktreePublishEntry]
  let reviews: [RepositoryWorktreeFileReview]
  @State private var search = ""

  private var visibleEntries: [RepositoryWorktreePublishEntry] {
    guard !search.isEmpty else { return entries }
    return entries.filter {
      $0.path.localizedCaseInsensitiveContains(search)
        || ($0.sourcePath?.localizedCaseInsensitiveContains(search) ?? false)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("审阅文件内容", systemImage: "doc.text.magnifyingglass")
        .font(.headline)
      Text("差异来自本次冻结快照；确认时仍会重新检查文件是否变化。")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("搜索文件路径", text: $search)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索文件路径")
        .accessibilityIdentifier("publish-worktree-file-search")
      if visibleEntries.isEmpty {
        Text(entries.isEmpty ? String(localized: "没有净文件差异。") : String(localized: "没有匹配的文件。"))
          .foregroundStyle(.secondary)
      }
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(visibleEntries) { entry in
          DisclosureGroup {
            if let review = reviews.first(where: { $0.entryID == entry.id }) {
              if let notice = review.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                  .foregroundStyle(WorkbenchTheme.warning)
                  .fixedSize(horizontal: false, vertical: true)
              }
              if let data = review.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                  .resizable()
                  .scaledToFit()
                  .frame(maxHeight: 260)
                  .accessibilityLabel("本次审阅的图片：\(entry.path)")
              }
              if !review.patch.isEmpty {
                ScrollView(.horizontal) {
                  Text(review.patch)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.vertical, 6)
                }
              } else if review.notice == nil {
                Text("仅文件状态变化，没有文本差异。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              Text("此快照没有内容差异，请重新审阅。")
                .foregroundStyle(WorkbenchTheme.warning)
            }
            DisclosureGroup(String(localized: "文件技术信息")) {
              Text(RepositoryWorktreePublishPresentation.metadataDescription(for: entry))
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
          } label: {
            Label {
              Text(RepositoryWorktreePublishPresentation.pathDescription(for: entry))
                .font(.callout)
                .textSelection(.enabled)
            } icon: {
              Image(systemName: entry.kind == .deleted ? "minus.circle" : "doc")
            }
            .accessibilityLabel(
              RepositoryWorktreePublishPresentation.accessibilityLabel(for: entry))
          }
          Divider()
        }
      }
    }
    .accessibilityIdentifier("publish-worktree-file-review")
  }
}

struct RepositoryPublishConfirmationFeedback: View {
  let feedback: PublishActionFeedback?
  let isPublishing: Bool
  let isReviewComplete: Bool
  let reviewAgainAction: () -> Void

  static func needsReview(_ feedback: PublishActionFeedback?) -> Bool {
    feedback?.status == .failure || feedback?.status == .warning
  }

  var body: some View {
    if !isReviewComplete || feedback != nil {
      VStack(alignment: .leading, spacing: 8) {
        if !isReviewComplete {
          Label(
            String(localized: "文件差异尚未完整审阅，请重新审阅后再发布。"),
            systemImage: "exclamationmark.triangle"
          )
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("publish-confirmation-review-incomplete")
          Button("重新审阅", action: reviewAgainAction)
            .disabled(isPublishing)
            .accessibilityIdentifier("publish-confirmation-review-again")
        }
        if let feedback {
          Label(
            feedback.message,
            systemImage: Self.needsReview(feedback) ? "exclamationmark.triangle" : "info.circle"
          )
          .font(.callout)
          .foregroundStyle(Self.needsReview(feedback) ? WorkbenchTheme.warning : .secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityIdentifier("publish-confirmation-feedback")
          if Self.needsReview(feedback), isReviewComplete {
            Button("重新审阅", action: reviewAgainAction)
              .disabled(isPublishing)
              .accessibilityIdentifier("publish-confirmation-review-again")
          }
        }
      }
      .padding(.horizontal, WorkbenchSpacing.spacious)
      .padding(.vertical, 10)
    }
  }
}
