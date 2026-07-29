import PublishingWorkbenchCore
import SwiftUI

struct AIChatConversationPicker: View {
  let draft: ArticleDraft
  let conversations: [AIConversation]
  let activeConversationID: AIConversation.ID?
  let isBusy: Bool
  let selectConversation: (AIConversation.ID) -> Void
  let createConversation: () -> Void
  let renameConversation: (AIConversation.ID, String?) -> Void
  let archiveConversation: (AIConversation.ID) -> Void
  let restoreConversation: (AIConversation.ID) -> Void
  let deleteConversation: (AIConversation.ID) -> Void

  @State private var searchText = ""
  @State private var conversationPendingRename: AIConversation?
  @State private var conversationPendingDeletion: AIConversation?
  @State private var renameText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("当前文章对话")
          .font(.headline)

        Spacer(minLength: 8)

        Button {
          createConversation()
        } label: {
          Label("新对话", systemImage: "square.and.pencil")
        }
        .controlSize(.small)
        .disabled(isBusy)
        .help("保留当前对话并新建")
      }

      TextField("搜索对话", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索 AI 对话")

      if filteredConversations.isEmpty {
        ContentUnavailableView(
          searchText.trimmedForPublishing.isEmpty ? "还没有对话" : "没有匹配的对话",
          systemImage: "bubble.left.and.text.bubble.right",
          description: Text(
            searchText.trimmedForPublishing.isEmpty
              ? "新建对话后，当前对话会保留在这里。"
              : "尝试修改搜索内容。"
          )
        )
        .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(filteredActiveConversations) { conversation in
              conversationRow(conversation)
            }

            if !filteredArchivedConversations.isEmpty {
              Divider()
                .padding(.vertical, 4)

              HStack {
                Label("已归档", systemImage: "archivebox")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredArchivedConversations.count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.tertiary)
              }
              .padding(.horizontal, 8)

              ForEach(filteredArchivedConversations) { conversation in
                conversationRow(conversation)
              }
            }
          }
          .padding(.vertical, 2)
        }
        .frame(maxHeight: 300)
      }

      Label("对话内容保存在本机；API Key 仍只存于钥匙串。", systemImage: "lock")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(width: 360)
    .sheet(item: $conversationPendingRename) { conversation in
      renameSheet(conversation)
    }
    .confirmationDialog(
      "删除这个对话？",
      isPresented: Binding(
        get: { conversationPendingDeletion != nil },
        set: { isPresented in
          if !isPresented {
            conversationPendingDeletion = nil
          }
        }
      ),
      titleVisibility: .visible,
      presenting: conversationPendingDeletion
    ) { conversation in
      Button("删除对话", role: .destructive) {
        deleteConversation(conversation.id)
        conversationPendingDeletion = nil
      }
      Button("取消", role: .cancel) {
        conversationPendingDeletion = nil
      }
    } message: { conversation in
      Text("“\(title(for: conversation))”及其中的消息将从本机删除。")
    }
  }

  private var filteredConversations: [AIConversation] {
    let query = searchText.trimmedForPublishing
    guard !query.isEmpty else { return conversations }
    return conversations.filter { conversation in
      title(for: conversation).localizedCaseInsensitiveContains(query)
        || preview(for: conversation).localizedCaseInsensitiveContains(query)
        || conversation.selectedModel.localizedCaseInsensitiveContains(query)
    }
  }

  private var filteredActiveConversations: [AIConversation] {
    filteredConversations.filter { !$0.isArchived }
  }

  private var filteredArchivedConversations: [AIConversation] {
    filteredConversations.filter(\.isArchived)
  }

  private func conversationRow(_ conversation: AIConversation) -> some View {
    HStack(spacing: 6) {
      Button {
        selectConversation(conversation.id)
      } label: {
        HStack(alignment: .top, spacing: 9) {
          Image(
            systemName: conversation.isArchived
              ? "archivebox"
              : (conversation.id == activeConversationID ? "checkmark.circle.fill" : "bubble.left")
          )
            .foregroundStyle(conversation.id == activeConversationID ? WorkbenchTheme.primary : .secondary)
            .frame(width: 16)

          VStack(alignment: .leading, spacing: 3) {
            Text(title(for: conversation))
              .font(.callout.weight(.medium))
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text(preview(for: conversation))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)

            HStack(spacing: 5) {
              Text(conversation.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))

              if !conversation.selectedModel.trimmedForPublishing.isEmpty {
                Text("·")
                Text(conversation.selectedModel)
                  .lineLimit(1)
              }
            }
            .font(.workbenchMetadata)
            .foregroundStyle(.tertiary)
          }

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(
        isBusy
          || conversation.isArchived
          || conversation.id == activeConversationID
      )
      .accessibilityLabel(title(for: conversation))
      .accessibilityValue(
        conversation.isArchived
          ? "已归档"
          : (conversation.id == activeConversationID ? "当前对话" : preview(for: conversation))
      )

      Menu {
        if conversation.isArchived {
          Button {
            restoreConversation(conversation.id)
          } label: {
            Label("恢复", systemImage: "arrow.uturn.backward")
          }
        } else {
          Button {
            renameText = title(for: conversation)
            conversationPendingRename = conversation
          } label: {
            Label("重命名", systemImage: "pencil")
          }

          Button {
            archiveConversation(conversation.id)
          } label: {
            Label("归档", systemImage: "archivebox")
          }
        }

        Button(role: .destructive) {
          conversationPendingDeletion = conversation
        } label: {
          Label("删除", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 24, height: 24)
      }
      .menuIndicator(.hidden)
      .disabled(isBusy)
      .help("更多对话操作")
      .accessibilityLabel("\(title(for: conversation))的更多操作")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(
          conversation.id == activeConversationID
            ? WorkbenchTheme.primary.opacity(0.10)
            : Color.clear
        )
    }
  }

  private func renameSheet(_ conversation: AIConversation) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("重命名对话")
        .font(.headline)

      TextField("对话名称", text: $renameText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("对话名称")

      HStack {
        Button("恢复自动标题") {
          renameConversation(conversation.id, nil)
          conversationPendingRename = nil
        }

        Spacer()

        Button("取消", role: .cancel) {
          conversationPendingRename = nil
        }

        Button("保存") {
          renameConversation(conversation.id, renameText)
          conversationPendingRename = nil
        }
        .workbenchProminentActionStyle()
        .disabled(renameText.trimmedForPublishing.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 360)
  }

  private func title(for conversation: AIConversation) -> String {
    if conversation.title?.trimmedForPublishing.nilIfEmpty == nil,
       !conversation.messages.contains(where: { $0.role == .user }) {
      return String(localized: "新对话")
    }
    return AIPublishingChatConversationPresentation.displayTitle(
      conversationTitle: conversation.title,
      messages: conversation.messages,
      draft: draft
    )
  }

  private func preview(for conversation: AIConversation) -> String {
    conversation.messages.last
      .map(AIPublishingChatMessageCompositionService.displayContent(for:))?
      .trimmedForPublishing
      .nilIfEmpty
      ?? String(localized: "暂无消息")
  }
}
