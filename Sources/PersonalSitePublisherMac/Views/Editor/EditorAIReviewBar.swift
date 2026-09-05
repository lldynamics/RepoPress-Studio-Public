import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// A single, keyboard-discoverable editor overlay for the active structured
/// hunk. It intentionally creates no per-hunk view hierarchy.
struct EditorAIReviewHunkPresentation: Equatable {
  let id: String
  let originalRange: NSRange
  let originalText: String
  let replacementText: String
  let reason: String
}

/// The editor prepares this once per render pass and shares it with both the
/// AppKit decoration and the SwiftUI review controls.
struct EditorAIReviewPresentation {
  let session: AIInlineStructuredEditReviewSession
  let hunk: EditorAIReviewHunkPresentation
  let position: (current: Int, total: Int)
  let decision: AIStructuredEditDecision

  var textViewPresentation: MarkdownEditorInlineAIReviewPresentation {
    MarkdownEditorInlineAIReviewPresentation(
      hunkID: hunk.id,
      bodyRange: hunk.originalRange,
      replacementText: hunk.replacementText
    )
  }
}

struct EditorAIReviewBar: View {
  let hunk: EditorAIReviewHunkPresentation
  let position: (current: Int, total: Int)
  let decision: AIStructuredEditDecision
  let onPrevious: () -> Void
  let onNext: () -> Void
  let onAccept: () -> Void
  let onReject: () -> Void
  let onAcceptAll: () -> Void
  let onRejectAll: () -> Void
  let onApply: () -> Void
  let onExit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("AI 修改审阅 \(position.current)/\(position.total)", systemImage: "text.badge.checkmark")
          .font(.callout.weight(.semibold))
        Spacer()
        Button("退出", action: onExit)
          .accessibilityIdentifier("editor-ai-review-exit")
      }
      Text(hunk.reason)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Label(decisionLabel, systemImage: decisionIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(decisionColor)
      Text(hunk.originalText)
        .font(.caption.monospaced())
        .strikethrough()
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Text(hunk.replacementText)
        .font(.caption.monospaced())
        .foregroundStyle(WorkbenchTheme.primary)
        .lineLimit(2)
      HStack {
        Button(action: onPrevious) { Label("上一个", systemImage: "chevron.up") }
          .accessibilityIdentifier("editor-ai-review-previous")
        Button(action: onNext) { Label("下一个", systemImage: "chevron.down") }
          .accessibilityIdentifier("editor-ai-review-next")
        Spacer()
        Button(action: onReject) { Label("拒绝", systemImage: "xmark") }
          .tint(decision == .rejected ? .red : nil)
          .accessibilityIdentifier("editor-ai-review-reject")
        Button(action: onAccept) { Label("接受", systemImage: "checkmark") }
          .tint(decision == .accepted ? WorkbenchTheme.primary : nil)
          .accessibilityIdentifier("editor-ai-review-accept")
      }
      HStack {
        Button("全部接受", action: onAcceptAll)
          .accessibilityIdentifier("editor-ai-review-accept-all")
        Button("全部拒绝", action: onRejectAll)
          .accessibilityIdentifier("editor-ai-review-reject-all")
        Spacer()
        Button(action: onApply) { Label("应用已接受", systemImage: "checkmark.seal") }
          .workbenchProminentActionStyle()
          .accessibilityIdentifier("editor-ai-review-apply")
      }
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkbenchTheme.primary.opacity(0.25)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("编辑器内 AI 修改审阅")
    .accessibilityValue(decisionLabel)
  }

  private var decisionLabel: String {
    switch decision {
    case .pending: "当前修改待处理"
    case .accepted: "当前修改已接受"
    case .rejected: "当前修改已拒绝"
    }
  }

  private var decisionIcon: String {
    switch decision {
    case .pending: "circle.dashed"
    case .accepted: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    }
  }

  private var decisionColor: Color {
    switch decision {
    case .pending: .secondary
    case .accepted: WorkbenchTheme.primary
    case .rejected: .red
    }
  }
}

extension MacMarkdownComposerView {
  var inlineStructuredEditReviewPresentation: EditorAIReviewPresentation? {
    guard let session = inlineAIReviewState.session(for: draft.id) else {
      return nil
    }
    let proposal =
      session.review.document.changes.first { $0.id == session.currentHunkID }
      ?? session.review.document.changes.first
    guard let proposal else { return nil }
    let hunk = EditorAIReviewHunkPresentation(
      id: proposal.id,
      originalRange: proposal.range.nsRange,
      originalText: proposal.originalText,
      replacementText: proposal.replacementText,
      reason: proposal.reason
    )
    let ids = session.review.document.changes.map(\.id)
    let index = session.currentHunkID.flatMap { ids.firstIndex(of: $0) } ?? 0
    return EditorAIReviewPresentation(
      session: session,
      hunk: hunk,
      position: (index + 1, ids.count),
      decision: session.review.decision(for: hunk.id)
    )
  }

  func applyInlineStructuredEditReview() {
    guard pendingInlineStructuredEditApplyRequestID == nil else { return }
    guard editorEditRequest == nil else {
      selectionActionMessage = "请等待当前编辑操作完成后再应用 AI 修改。"
      EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
      return
    }
    guard
      let session = aiActions.validatedInlineStructuredEditReviewSession(
        for: draft,
        body: editorBody
      )
    else {
      selectionActionMessage = "尚未接受任何修改。"
      EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
      return
    }
    let result: AIStructuredEditApplicationResult
    do {
      result = try AIStructuredEditReviewService.apply(session.review, to: session.sourceBody)
    } catch {
      selectionActionMessage = "AI 修改无法应用：\(error.localizedDescription)"
      EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
      return
    }
    guard result.hasAppliedChanges else {
      selectionActionMessage = "尚未接受任何修改。"
      EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
      return
    }
    guard result.finalBody != editorBody else {
      selectionActionMessage = "接受的修改未改变正文。"
      EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
      return
    }
    var updated = draft
    updated.bodyMarkdown = result.finalBody
    guard requestUndoableBodyUpdate(updated), let requestID = editorEditRequest?.id else {
      selectionActionMessage = "AI 修改未能加入编辑器撤销队列。"
      EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
      return
    }
    pendingInlineStructuredEditApplyRequestID = requestID
    selectionActionMessage = "正在应用已接受的 AI 修改…"
  }
}
