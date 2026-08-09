import PublishingWorkbenchCore
import SwiftUI

struct AIChatMessageList: View {
  let conversationID: UUID
  let messages: [AIPublishingChatMessage]
  let isBusy: Bool
  @State private var isFollowingLatestMessage = true

  private static let latestMessageAnchorID = "ai-chat-latest-message-anchor"

  private var messageContentSignature: [String] {
    messages.map { "\($0.id.uuidString):\($0.content)" }
  }

  var body: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ZStack(alignment: .bottomTrailing) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if messages.isEmpty {
                EmptyStateView(
                  title: "开始通用对话",
                  message: "这里不会自动读取文章、选区、仓库或发布状态。需要时，用 @ 明确附加上下文。",
                  systemImage: "bubble.left.and.bubble.right",
                  density: .compactPane
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .accessibilityIdentifier("ai-chat-empty-state")
              }

              ForEach(messages) { message in
                AIChatMessageSurface(role: message.role) {
                  VStack(alignment: .leading, spacing: 8) {
                    if message.content.nilIfEmpty == nil && isBusy && message.role == .assistant {
                      ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("AI 正在生成回复")
                    } else {
                      Text(verbatim: message.content)
                        .font(.workbenchBody)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if !message.contextReferences.isEmpty {
                      Label(
                        message.contextReferences
                          .map(aiChatContextReferenceLabel)
                          .joined(separator: "、"),
                        systemImage: "at"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .accessibilityLabel("本次明确附加的上下文")
                    }

                    if !message.knowledgeCitations.isEmpty {
                      Label(
                        "资料库引用 \(message.knowledgeCitations.count) 条",
                        systemImage: "books.vertical"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("ai-chat-message-\(message.id.uuidString)")
                .id(message.id)
              }

              Color.clear
                .frame(height: 1)
                .background {
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: AIChatScrollBottomPreferenceKey.self,
                      value: geometry.frame(in: .named("ai-chat-message-scroll")).maxY
                    )
                  }
                }
                .id(Self.latestMessageAnchorID)
            }
            .padding(16)
          }
          .coordinateSpace(name: "ai-chat-message-scroll")
          .onPreferenceChange(AIChatScrollBottomPreferenceKey.self) { bottomPosition in
            guard bottomPosition > 0 else { return }
            isFollowingLatestMessage = bottomPosition <= viewport.size.height + 56
          }
          .onAppear {
            scrollToLatest(using: proxy, animated: false)
          }
          .onChange(of: conversationID) { previousID, newID in
            guard AIChatMessageListFollowPolicy.shouldResetFollowState(
              previousConversationID: previousID,
              newConversationID: newID
            ) else { return }
            isFollowingLatestMessage = true
            scrollToLatest(using: proxy, animated: false)
          }
          .onChange(of: messageContentSignature) { _, _ in
            let shouldFollow = AIChatMessageListFollowPolicy.shouldFollowLatest(
              isFollowingLatest: isFollowingLatestMessage,
              contentChanged: true
            )
            guard shouldFollow else { return }
            scrollToLatest(using: proxy, animated: !isBusy)
          }

          if !isFollowingLatestMessage && !messages.isEmpty {
            Button {
              isFollowingLatestMessage = true
              scrollToLatest(using: proxy, animated: true)
            } label: {
              Label("跳到最新", systemImage: "arrow.down.circle.fill")
            }
            .controlSize(.small)
            .padding(10)
            .accessibilityLabel("跳到最新消息")
            .accessibilityIdentifier("ai-chat-jump-to-latest")
            .accessibilityHint("返回正在更新的最新 AI 消息")
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 对话消息")
    .accessibilityIdentifier("ai-chat-message-list")
  }

  private func scrollToLatest(
    using proxy: ScrollViewProxy,
    animated: Bool
  ) {
    guard !messages.isEmpty else { return }
    let action = {
      proxy.scrollTo(Self.latestMessageAnchorID, anchor: .bottom)
    }
    if animated {
      withAnimation(.easeOut(duration: 0.18), action)
    } else {
      action()
    }
  }
}

struct AIChatHeader: View {
  let title: String
  let subtitle: String
  let profiles: [AIConnectionProfile]
  let selectedConnectionProfileID: UUID?
  let modelGrade: AIChatModelGrade
  let isBusy: Bool
  let isControlsDisabled: Bool
  let onSelectConnectionProfile: (UUID) -> Void
  let onSelectModelGrade: (AIChatModelGrade) -> Void
  let onNewConversation: () -> Void
  let onStop: () -> Void

  private var validSelectedConnectionProfileID: UUID? {
    guard let selectedConnectionProfileID else { return nil }
    return profiles.contains(where: { $0.id == selectedConnectionProfileID })
      ? selectedConnectionProfileID
      : nil
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        headerIcon
        headerTitle
        headerControls
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          headerIcon
          headerTitle
        }
        HStack(spacing: 8) {
          headerControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.thinMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("通用 AI 对话标题栏")
    .accessibilityIdentifier("ai-chat-header")
  }

  private var headerIcon: some View {
    Image(systemName: "sparkles")
      .font(.title3.weight(.semibold))
      .foregroundStyle(Color.accentColor)
      .accessibilityHidden(true)
  }

  private var headerTitle: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .minimumScaleFactor(0.82)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var headerControls: some View {
    if !profiles.isEmpty {
      Picker(
        "AI 连接档案",
        selection: Binding<UUID?>(
          get: { validSelectedConnectionProfileID },
          set: { selectedID in
            if let selectedID {
              onSelectConnectionProfile(selectedID)
            }
          }
        )
      ) {
        Text(
          selectedConnectionProfileID == nil
            ? String(localized: "未选择")
            : String(localized: "未选择（连接档案已失效）")
        )
        .tag(nil as UUID?)
        ForEach(profiles) { profile in
          Text(profile.name).tag(profile.id as UUID?)
        }
      }
      .labelsHidden()
      .frame(minWidth: 150, maxWidth: 240)
      .accessibilityLabel("AI 连接档案")
      .accessibilityValue(
        profiles.first { $0.id == selectedConnectionProfileID }?.name
          ?? (
            selectedConnectionProfileID == nil
              ? String(localized: "未选择")
              : String(localized: "连接档案已失效")
          )
      )
      .accessibilityIdentifier("ai-chat-connection-profile-picker")
      .accessibilityHint("选择此会话使用的 AI 连接档案")
      .disabled(isBusy || isControlsDisabled)
    }

    Picker(
      "AI 模型",
      selection: Binding(
        get: { modelGrade },
        set: onSelectModelGrade
      )
    ) {
      ForEach(AIChatModelGrade.allCases) { grade in
        Text(grade.title).tag(grade)
      }
    }
    .labelsHidden()
    .frame(minWidth: 90, maxWidth: 130)
    .accessibilityLabel("AI 模型")
    .accessibilityValue(modelGrade.title)
    .accessibilityIdentifier("ai-chat-model-picker")
    .accessibilityHint("选择此会话使用的 AI 模型档位")
    .disabled(isBusy || isControlsDisabled)

    if isBusy {
      Button(action: onStop) {
        Label("停止", systemImage: "stop.circle")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .keyboardShortcut(".", modifiers: [.command])
      .accessibilityLabel("停止 AI 回复")
      .accessibilityIdentifier("ai-chat-header-stop")
      .accessibilityHint("停止当前通用 AI 回复")
    }

    Button(action: onNewConversation) {
      Label("新对话", systemImage: "square.and.pencil")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isBusy || isControlsDisabled)
    .accessibilityLabel("新建通用 AI 对话")
    .accessibilityIdentifier("ai-chat-header-new-conversation")
    .accessibilityHint("创建并切换到一条新的通用 AI 对话")
  }
}

struct AIChatComposer: View {
  @Binding var text: String
  let isSending: Bool
  let isDisabled: Bool
  let composerFocus: FocusState<Bool>.Binding
  let contextReferences: [AIContextReference]
  let imageAttachments: [AIChatImageAttachment]
  let availableContextReferences: [AIContextReference]
  let onToggleContextReference: (AIContextReference) -> Void
  let onRemoveContextReference: (AIContextReference) -> Void
  let onAddAttachment: () -> Void
  let onRemoveAttachment: (AIChatImageAttachment) -> Void
  let onSend: () -> Void
  let onStop: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      let envelope = AIContextAssembler.generalEnvelope(
        explicitContextReferences: contextReferences
      )
      Text(
        "本次将发送用户消息和\(envelope.transmissionSummary.displayText)；不会自动携带当前文章、选区、仓库或发布状态。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(3)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(
        "本次发送内容预览：\(envelope.transmissionSummary.displayText)。不会自动携带当前文章、选区、仓库或发布状态"
      )
      .accessibilityIdentifier("ai-chat-context-preview")

      if !contextReferences.isEmpty || !imageAttachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: true) {
          HStack(spacing: 6) {
            ForEach(contextReferences) { reference in
              removableChip(
                title: aiChatContextReferenceLabel(reference),
                icon: "at"
              ) {
                onRemoveContextReference(reference)
              }
            }
            ForEach(imageAttachments, id: \.filename) { attachment in
              removableChip(title: attachment.filename, icon: "photo") {
                onRemoveAttachment(attachment)
              }
            }
          }
        }
        .accessibilityLabel("待发送附件和上下文")
        .accessibilityIdentifier("ai-chat-attachments-preview")
      }

      TextField("输入问题；⌘Return 发送", text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.body)
        .lineLimit(3...8)
        .disabled(isSending || isDisabled)
        .focused(composerFocus)
        .accessibilityLabel("通用 AI 消息")
        .accessibilityHint("可以用 @ 菜单明确附加文章、选区、站点或资料库内容")
        .accessibilityIdentifier("ai-chat-input")

      HStack(spacing: 8) {
        Menu {
          if availableContextReferences.isEmpty {
            Text("当前没有可附加的上下文")
          } else {
            ForEach(availableContextReferences) { reference in
              Button {
                onToggleContextReference(reference)
              } label: {
                Label(
                  aiChatContextReferenceLabel(reference),
                  systemImage: contextReferences.contains(reference)
                    ? "checkmark.circle.fill" : "circle"
                )
              }
            }
          }
        } label: {
          Label("添加上下文", systemImage: "at")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("添加明确上下文")
        .accessibilityIdentifier("ai-chat-add-context")
        .accessibilityHint("选择要明确附加到本次请求的文章、选区、站点或资料库内容")
        .disabled(isSending || isDisabled)

        Button(action: onAddAttachment) {
          Label("添加图片", systemImage: "paperclip")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("添加图片附件")
        .accessibilityIdentifier("ai-chat-add-image")
        .accessibilityHint("从文件中选择要附加到本次请求的图片")
        .disabled(isSending || isDisabled)

        Spacer(minLength: 0)

        if isSending {
          Button(action: onStop) {
            Label("停止", systemImage: "stop.circle.fill")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityLabel("停止 AI 回复")
          .accessibilityIdentifier("ai-chat-composer-stop")
          .accessibilityHint("停止当前通用 AI 回复")
        } else {
          Button(action: onSend) {
            Label("发送", systemImage: "arrow.up.circle.fill")
          }
          .workbenchProminentActionStyle()
          .controlSize(.small)
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(
            isDisabled
              || (text.trimmedForPublishing.isEmpty && imageAttachments.isEmpty)
          )
          .accessibilityLabel("发送通用 AI 消息")
          .accessibilityIdentifier("ai-chat-send")
          .accessibilityHint("发送当前输入；也可以按 Command-Return")
        }
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    )
    .padding(12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-chat-composer")
  }

  private func removableChip(
    title: String,
    icon: String,
    remove: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
      Text(title).lineLimit(1)
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("移除 \(title)")
    }
    .font(.caption)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.07), in: Capsule())
  }
}

private func aiChatContextReferenceLabel(_ reference: AIContextReference) -> String {
  AIContextTransmissionSummaryService.make(references: [reference]).items.first?.label
    ?? String(localized: "上下文")
}
