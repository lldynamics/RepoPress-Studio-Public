import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatMessageSurface<Content: View>: View {
  let role: AIPublishingChatRole
  let timestamp: Date?
  let headerAccessory: (() -> AnyView)?
  @ViewBuilder let content: () -> Content

  init(
    role: AIPublishingChatRole,
    timestamp: Date? = nil,
    headerAccessory: (() -> AnyView)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.role = role
    self.timestamp = timestamp
    self.headerAccessory = headerAccessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 6) {
        if isUser {
          Spacer(minLength: 0)
        }
        Image(systemName: isUser ? "person.crop.circle" : "sparkles")
          .font(.workbenchMetadata.weight(.semibold))
        Text(verbatim: role.localizedDisplayName)
          .font(.workbenchSupporting.weight(.semibold))
        if let timestamp {
          Text(timestamp.formatted(date: .omitted, time: .shortened))
            .font(.workbenchMetadata.monospacedDigit())
            .foregroundStyle(.workbenchSecondary)
        }
        if !isUser {
          Spacer(minLength: 0)
        }
        if let headerAccessory {
          headerAccessory()
        }
      }
      .foregroundStyle(isUser ? Color.primary : Color.secondary)
      .padding(.horizontal, WorkbenchSpacing.tight)

      content()
        .padding(.horizontal, WorkbenchSpacing.card)
        .padding(.vertical, WorkbenchSpacing.control)
        .frame(
          maxWidth: isUser ? 390 : .infinity,
          alignment: isUser ? .trailing : .leading
        )
        .background {
          RoundedRectangle(
            cornerRadius: isUser ? 14 : WorkbenchCornerRadius.control,
            style: .continuous
          )
          .fill(isUser ? AnyShapeStyle(.thinMaterial) : WorkbenchBackgroundStyle.card)
          if isUser {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.bubble, style: .continuous)
              .fill(Color.primary.opacity(0.04))
          }
        }
        .overlay {
          RoundedRectangle(
            cornerRadius: isUser ? 14 : WorkbenchCornerRadius.control,
            style: .continuous
          )
          .stroke(
            isUser ? Color.primary.opacity(0.12) : Color.primary.opacity(0.08),
            lineWidth: 1
          )
        }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private var isUser: Bool {
    role == .user
  }
}

struct AIChatAssistantMessageContent: View, Equatable {
  let content: String
  let presentation: AIChatAssistantMessagePresentationMode
  let actions: AIChatContextInspectorActions
  let draft: ArticleDraft?

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    // The command closures stay bound to the same Inspector. Content,
    // presentation mode, and the action target draft are the value inputs
    // that determine whether this subtree must be rebuilt.
    lhs.content == rhs.content
      && lhs.presentation == rhs.presentation
      && lhs.draft == rhs.draft
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      switch presentation {
      case .streamingText:
        Text(verbatim: content)
          .font(.workbenchBody)
          .lineSpacing(3)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

      case .structured:
        ForEach(AIChatCodeBlockPresentationService.segments(in: content)) { segment in
          switch segment {
          case .text(_, let text):
            if !text.isEmpty {
              Text(verbatim: text)
                .font(.workbenchBody)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          case .code(let block):
            if let draft {
              AIChatCodeBlockActionCard(
                block: block,
                apply: { actions.applyCodeBlock(block, draft) },
                insertAtCursor: { actions.insertCodeBlockAtCursor(block, draft) },
                copy: { actions.copyCodeBlock(block) }
              )
            } else {
              AIChatCodeBlockReadOnlyCard(block: block) { actions.copyCodeBlock(block) }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AIChatCodeBlockReadOnlyCard: View {
  let block: AIChatCodeBlock
  let copy: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(block.language?.uppercased() ?? String(localized: "MARKDOWN"))
          .font(.workbenchMetadata.weight(.semibold))
        Spacer(minLength: 8)
        Button(action: copy) {
          Label(String(localized: "复制"), systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(String(localized: "复制代码块"))
        .accessibilityIdentifier("ai-code-block-copy")
      }
      ScrollView(.horizontal, showsIndicators: true) {
        Text(verbatim: block.content.isEmpty ? String(localized: "（空代码块）") : block.content)
          .font(.workbenchMetadata.monospaced())
          .lineSpacing(2)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(WorkbenchSpacing.control)
      }
      .frame(maxHeight: 260)
    }
    .padding(WorkbenchSpacing.control)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityLabel(String(localized: "代码块，只读"))
  }
}

struct AIChatCodeBlockActionCard: View {
  let block: AIChatCodeBlock
  let apply: () -> Void
  let insertAtCursor: () -> Void
  let copy: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 6) {
        Label(
          block.language?.uppercased() ?? String(localized: "MARKDOWN"),
          systemImage: "chevron.left.forwardslash.chevron.right"
        )
        .font(.workbenchMetadata.weight(.semibold))
        .foregroundStyle(.workbenchSecondary)

        Spacer(minLength: 8)

        Button(action: apply) {
          Label("Apply", systemImage: "arrow.down.to.line.compact")
        }
        .workbenchProminentActionStyle()
        .controlSize(.small)
        .help(String(localized: "一键应用到当前编辑器"))
        .accessibilityLabel(String(localized: "一键应用到当前编辑器"))
        .accessibilityIdentifier("ai-code-block-apply")

        Button(action: insertAtCursor) {
          Label(String(localized: "插入"), systemImage: "text.insert")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(String(localized: "插入到光标处"))
        .accessibilityLabel(String(localized: "插入到光标处"))
        .accessibilityIdentifier("ai-code-block-insert")

        Button(action: copy) {
          Label(String(localized: "复制"), systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(String(localized: "复制完整 Markdown 代码块"))
        .accessibilityLabel(String(localized: "复制代码块"))
        .accessibilityIdentifier("ai-code-block-copy")
      }

      ScrollView(.horizontal, showsIndicators: true) {
        Text(verbatim: block.content.isEmpty ? String(localized: "（空代码块）") : block.content)
          .font(.workbenchMetadata.monospaced())
          .lineSpacing(2)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(WorkbenchSpacing.control)
      }
      .frame(maxHeight: 260)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .padding(WorkbenchSpacing.control)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card, style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    )
  }
}
