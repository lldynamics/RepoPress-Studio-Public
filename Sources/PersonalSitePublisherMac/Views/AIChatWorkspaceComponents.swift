import SwiftUI
import PublishingWorkbenchCore

struct AIChatContextOverviewState {
  let draftTitle: String
  let markdownPath: String
  let contextModeDisplayName: String
  let contextModeSystemImage: String
  let modelText: String
  let retrievalBasis: String
  let tokenDisplayText: String
  let costDisplayText: String
  let imageInputText: String
  let focusedParagraphTitle: String?
  let shouldShowPublicCandidates: Bool
  let publicCandidateCount: Int
  let relatedSuggestionCount: Int
  let attachmentCount: Int
}

struct ContextOverview: View {
  let state: AIChatContextOverviewState
  let isExpanded: Bool
  let onToggleExpanded: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 5) {
          Text(state.draftTitle)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(state.markdownPath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 12)

        VStack(alignment: .trailing, spacing: 5) {
          Label(state.contextModeDisplayName, systemImage: state.contextModeSystemImage)
          Label(state.modelText, systemImage: "cpu")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

        Button {
          onToggleExpanded()
        } label: {
          Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
            .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isExpanded ? "收起上下文详情" : "展开上下文详情")
        .help(isExpanded ? "收起上下文详情" : "展开上下文详情")
      }

      if isExpanded {
        Divider()

        HStack(alignment: .top, spacing: 18) {
          VStack(alignment: .leading, spacing: 6) {
            Label(state.retrievalBasis, systemImage: "scope")
            Label(state.tokenDisplayText, systemImage: "gauge.with.dots.needle.bottom.50percent")
            Label(state.costDisplayText, systemImage: "dollarsign.circle")
            Label(state.imageInputText, systemImage: "photo.badge.checkmark")
          }

          VStack(alignment: .leading, spacing: 6) {
            if let focusedParagraphTitle = state.focusedParagraphTitle {
              Label(focusedParagraphTitle, systemImage: "text.quote")
            }
            if state.shouldShowPublicCandidates {
              Label("\(state.publicCandidateCount) 篇公开候选", systemImage: "globe")
            }
            if state.relatedSuggestionCount > 0 {
              Label("\(state.relatedSuggestionCount) 条关联建议", systemImage: "link")
            }
            if state.attachmentCount > 0 {
              Label("\(state.attachmentCount) 张图片", systemImage: "photo.on.rectangle")
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

struct QuickPromptGrid: View {
  @Binding var capabilityMode: AIPublishingCapabilityCenterMode
  let isAIChatRunning: Bool
  let onPromptSelected: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      workflowGuideGrid
      capabilityModePicker
      editorActionCenter

      ForEach(snapshot.promptSections) { section in
        VStack(alignment: .leading, spacing: 8) {
          Label(section.group.displayName, systemImage: section.group.systemImage)
            .font(.headline)
          Text(section.group.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

          LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
            ForEach(section.prompts) { prompt in
              Button {
                onPromptSelected(prompt.prompt)
              } label: {
                Label(prompt.displayName, systemImage: prompt.systemImage)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.bordered)
              .disabled(isAIChatRunning)
            }
          }
        }
      }
    }
  }

  private var snapshot: AIPublishingCapabilityCenterSnapshot {
    AIPublishingCapabilityCenterService.snapshot(mode: capabilityMode)
  }

  private var capabilityModePicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("AI 能力范围", selection: $capabilityMode) {
        ForEach(AIPublishingCapabilityCenterMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 280)
      .accessibilityLabel("AI 能力范围")
      .accessibilityValue(capabilityMode.displayName)

      Text(capabilityMode.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var editorActionCenter: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("编辑器 AI 动作", systemImage: "sparkles")
        .font(.headline)
      Text("复用正文编辑器的 AI 能力，适合先放进聊天输入框，发送前继续补充要求。")
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(snapshot.editorActionSections) { section in
        DisclosureGroup {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
            ForEach(section.actions) { action in
              Button {
                onPromptSelected(AIPublishingChatPromptTemplateService.editorActionPrompt(for: action))
              } label: {
                Label(action.displayName, systemImage: action.promptLibrarySystemImage)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.bordered)
              .disabled(isAIChatRunning)
            }
          }
          .padding(.top, 6)
        } label: {
          Label(section.group.displayName, systemImage: section.group.systemImage)
            .font(.callout.weight(.semibold))
        }
      }
    }
  }

  private var workflowGuideGrid: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("AI 工作流", systemImage: "sparkles.rectangle.stack")
        .font(.headline)
      Text("把多个手机版 AI 动作串成一次可执行的写作、发布或维护流程。")
        .font(.caption)
        .foregroundStyle(.secondary)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
        ForEach(AIPublishingWorkflowGuide.featuredGuides) { guide in
          Button {
            onPromptSelected(AIPublishingChatPromptTemplateService.workflowGuidePrompt(for: guide))
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: guide.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 3) {
                Text(guide.title)
                  .font(.callout.weight(.medium))
                  .lineLimit(1)
                Text(guide.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                Text(guide.actionPreview)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .accessibilityLabel("使用 AI 工作流")
          .accessibilityValue(guide.title)
          .disabled(isAIChatRunning)
        }
      }
    }
  }
}

struct AIChatMessageRow: View {
  let message: AIPublishingChatMessage
  let actionAvailability: AIPublishingChatMessageActionAvailability
  let canReplaceSelection: Bool
  let onCopy: () -> Void
  let onQuote: () -> Void
  let onDelete: () -> Void
  let onBranch: () -> Void
  let onRegenerate: () -> Void
  let onAppendToBody: () -> Void
  let onReplaceSelection: () -> Void
  let onReplaceBody: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      if message.role == .user {
        Spacer(minLength: 80)
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Label(message.role.displayName, systemImage: message.role == .user ? "person.crop.circle" : "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(message.createdAt.workbenchShortText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
          if let metadataText {
            Text(metadataText)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Button {
            onCopy()
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("复制")
          .disabled(!actionAvailability.canCopy)
          .accessibilityLabel("复制消息")
          Button {
            onQuote()
          } label: {
            Image(systemName: "quote.bubble")
          }
          .buttonStyle(.borderless)
          .help("引用追问")
          .disabled(!actionAvailability.canQuote)
          .accessibilityLabel("引用这条消息追问")
          Button(role: .destructive) {
            onDelete()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("删除消息")
          .accessibilityLabel("删除消息")
          Button {
            onBranch()
          } label: {
            Image(systemName: "arrow.triangle.branch")
          }
          .buttonStyle(.borderless)
          .help("从此处分支")
          .disabled(!actionAvailability.canQuote)
          .accessibilityLabel("从这条消息处分支对话")
          if actionAvailability.canRegenerate {
            Button {
              onRegenerate()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新生成此回复")
            .accessibilityLabel("重新生成此回复")
          }
          if actionAvailability.canApplyToArticle {
            Menu {
              Button {
                onAppendToBody()
              } label: {
                Label("追加到文章末尾", systemImage: "text.append")
              }
              Button {
                onReplaceSelection()
              } label: {
                Label("替换当前选区", systemImage: "text.badge.checkmark")
              }
              .disabled(!canReplaceSelection)
              Button(role: .destructive) {
                onReplaceBody()
              } label: {
                Label("替换整篇正文", systemImage: "doc.text.fill")
              }
            } label: {
              Image(systemName: "text.badge.checkmark")
            }
            .buttonStyle(.borderless)
            .help("应用到文章")
            .disabled(trimmedMessageContent.isEmpty)
            .accessibilityLabel("应用 AI 回复到文章")
          }
        }

        if !trimmedMessageContent.isEmpty {
          Text(message.content)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !message.imageAttachments.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Label("\(message.imageAttachments.count) 张图片附件", systemImage: "photo.on.rectangle")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            ForEach(message.imageAttachments, id: \.self) { attachment in
              Text(attachment.filename)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }
        }
      }
      .padding(12)
      .frame(maxWidth: 720, alignment: .leading)
      .background(backgroundStyle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))

      if message.role == .assistant {
        Spacer(minLength: 80)
      }
    }
  }

  private var trimmedMessageContent: String {
    message.content.trimmedForPublishing
  }

  private var metadataText: String? {
    guard message.role == .assistant else {
      return nil
    }
    let parts = [
      message.model?.nilIfEmpty,
      message.tokenUsage?.displayText.nilIfEmpty,
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var backgroundStyle: AnyShapeStyle {
    if message.role == .user {
      return AnyShapeStyle(WorkbenchTheme.primary.opacity(WorkbenchOpacity.selectionBackground))
    }
    return AnyShapeStyle(Color.secondary.opacity(WorkbenchOpacity.noticeBackground))
  }
}
