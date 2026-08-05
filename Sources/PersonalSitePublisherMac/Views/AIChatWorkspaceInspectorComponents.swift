import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatContextInspectorView: View {
  @Environment(\.openSettings) var openSettings
  @AppStorage("settingsRequestedTabID") var requestedSettingsTabID = ""
  @ObservedObject var ai: WorkbenchAIFeatureFacade
  @State var inputText = ""
  @State var isSubmitting = false
  @State var sendTask: Task<Void, Never>?
  @State var latestMessageScrollTask: Task<Void, Never>?
  @State var draftDiffPreview: AIChatDraftDiffPreview?
  @State var visibleMessageLimit = 8
  @State var isFollowingLatestMessage = true
  @State var messageAnchorToPreserve: AIPublishingChatMessage.ID?
  @State var isPartialRetryConfirmationPresented = false
  @State var isConversationPopoverPresented = false
  @State var isModelQuickSwitchPresented = false
  @State var selectedImageAttachmentIDs: Set<UUID> = []
  @State var selectedContextReferences: [AIContextReference] = []
  @State var isAdvancedSettingsExpanded = false
  @FocusState var isComposerFocused: Bool
  @State var isHeaderTitleHovered = false

  init(store: WorkbenchStore) {
    _ai = ObservedObject(wrappedValue: store.ai)
  }

  var body: some View {
    VStack(spacing: 0) {
      inspectorHeader

      Divider()

      if isAIKeyMissing {
        missingAIKeyBanner
        Divider()
      }

      GeometryReader { viewport in
        ScrollViewReader { proxy in
          ScrollView {
            AIChatContextInspectorContent(state: state, actions: actions)
              .padding(16)

            Color.clear
              .frame(height: 1)
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(
                    key: AIChatScrollBottomPreferenceKey.self,
                    value: geometry.frame(in: .named("ai-chat-scroll")).maxY
                  )
                }
              }
          }
          .coordinateSpace(name: "ai-chat-scroll")
          .onPreferenceChange(AIChatScrollBottomPreferenceKey.self) { bottomPosition in
            guard bottomPosition > 0 else { return }
            isFollowingLatestMessage = bottomPosition <= viewport.size.height + 56
          }
          .overlay(alignment: .bottomTrailing) {
            if !isFollowingLatestMessage, latestMessageID != nil {
              Button {
                isFollowingLatestMessage = true
                scrollToLatestMessage(using: proxy)
              } label: {
                Label(
                  String(localized: "跳到最新"),
                  systemImage: "arrow.down.circle.fill"
                )
              }
              .controlSize(.small)
              .padding(10)
            }
          }
          .onAppear {
            scrollToLatestMessage(using: proxy, animated: false)
          }
          .onChange(of: latestMessageID) { _, _ in
            guard isFollowingLatestMessage else { return }
            scheduleLatestMessageScroll(
              using: proxy,
              animated: !isSending
            )
          }
          .onChange(of: latestMessageContent) { _, _ in
            guard isFollowingLatestMessage else { return }
            scheduleLatestMessageScroll(
              using: proxy,
              animated: false,
              delayNanoseconds: 75_000_000
            )
          }
          .onChange(of: visibleMessageLimit) { _, _ in
            guard let anchor = messageAnchorToPreserve else { return }
            DispatchQueue.main.async {
              proxy.scrollTo(anchor, anchor: .top)
              messageAnchorToPreserve = nil
            }
          }
        }
      }

      Divider()

      messageComposer
    }
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 助手")
    .accessibilityIdentifier("ai-assistant-inspector")
    .onAppear {
      synchronizeChatDraftWithSelection()
      applyPendingQuickPrompt()
      focusComposerIfAvailable()
    }
    .onDisappear {
      latestMessageScrollTask?.cancel()
    }
    .onChange(of: ai.selectedChatDraft?.id) { _, _ in
      selectedImageAttachmentIDs = []
      selectedContextReferences = []
      synchronizeChatDraftWithSelection()
    }
    .onChange(of: ai.pendingQuickPrompt?.id) { _, _ in
      applyPendingQuickPrompt()
    }
    .onChange(of: isAIKeyMissing) { _, isMissing in
      if !isMissing {
        focusComposerIfAvailable()
      }
    }
    .onChange(of: ai.chatDraftID) { _, _ in
      visibleMessageLimit = 8
      isFollowingLatestMessage = true
    }
    .onChange(of: ai.activeChatConversationID) { _, _ in
      visibleMessageLimit = 8
      isFollowingLatestMessage = true
    }
    .onChange(of: ai.chatMessages.count) { _, count in
      if count == 0 {
        visibleMessageLimit = 8
        isFollowingLatestMessage = true
      }
    }
    .sheet(item: $draftDiffPreview) { preview in
      AIChatDraftDiffPreviewSheet(preview: preview) {
        applyDraftDiffPreview(preview)
      }
    }
    .sheet(isPresented: $isModelQuickSwitchPresented) {
      AIChatModelQuickSwitchSheet(
        ai: ai,
        draft: ai.selectedChatDraft
      )
    }
    .confirmationDialog(
      String(localized: "重新生成可能重复计费"),
      isPresented: $isPartialRetryConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(String(localized: "仍要重新生成"), role: .destructive) {
        retryLastFailedReply(confirmingPossibleDuplicateCharge: true)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("AI 已返回部分内容，软件没有自动重放请求。继续会移除这段未完成回复并重新生成，可能产生重复内容和费用。")
    }
  }
}
