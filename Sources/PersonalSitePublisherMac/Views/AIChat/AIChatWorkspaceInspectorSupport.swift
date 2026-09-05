import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatContextInspectorContent: View {
  let state: AIChatContextInspectorState
  let actions: AIChatContextInspectorActions

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let conversation = state.conversation {
        AIChatConversationInspectorSection(context: conversation, actions: actions)
        AIChatRelatedSuggestionsInspectorSection(context: conversation, actions: actions)
      } else {
        EmptyStateView(
          title: "没有上下文",
          message: "选择文章后，这里显示 AI 对话上下文。",
          systemImage: "sparkles",
          density: .compactPane
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AIChatInspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(verbatim: title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
