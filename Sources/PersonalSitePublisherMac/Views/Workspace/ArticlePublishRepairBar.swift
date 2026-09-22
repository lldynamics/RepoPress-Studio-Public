import PublishingWorkbenchCore
import SwiftUI

/// Window-local state for a repair entered from the publishing checklist.
/// It deliberately keeps the publish scope and exact article identity so a
/// return to publishing cannot silently switch to another draft.
struct ArticlePublishRepairSession: Identifiable, Equatable {
  let id = UUID()
  let draftID: UUID
  let target: PublishReadinessTarget
  let publishScope: PublishScope
}

/// A non-modal return path while an author repairs a publishing issue in the
/// editor or article Inspector. It never publishes; returning first rebuilds
/// the current preview and then reopens the regular publishing checklist.
struct ArticlePublishRepairBar: View {
  let session: ArticlePublishRepairSession
  let isReturningToPublishChecks: Bool
  let returnToPublishChecks: () -> Void
  let endRepair: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "wrench.and.screwdriver")
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("正在修复发布问题")
          .font(.callout.weight(.semibold))
        Text(session.target.title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Button("结束修复", action: endRepair)
        .buttonStyle(.borderless)
        .disabled(isReturningToPublishChecks)
        .accessibilityIdentifier("article-publish-repair-end")

      Button {
        returnToPublishChecks()
      } label: {
        Label(
          isReturningToPublishChecks ? "正在刷新发布预览" : "返回发布检查",
          systemImage: "arrow.uturn.backward"
        )
      }
      .workbenchProminentActionStyle()
      .keyboardShortcut("r", modifiers: [.command, .option])
      .disabled(isReturningToPublishChecks)
      .accessibilityIdentifier("article-publish-repair-return")
      .accessibilityLabel("返回发布检查")
      .accessibilityHint("重新生成当前文章的发布预览，不会自动发布")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: 720)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("article-publish-repair-bar")
    .accessibilityLabel("正在修复发布问题")
    .accessibilityValue(session.target.title)
  }
}
