import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatGeneralKeyAvailabilityRefreshKey: Equatable {
  let connectionProfileID: UUID?
  let providerConfig: AIProviderConfig?
  let activeTokenAvailability: KeychainTokenAvailability
}

struct AIChatContextInspectorView: View {
  @Environment(\.openSettings) var openSettings
  @AppStorage("settingsRequestedTabID") var requestedSettingsTabID = ""
  let ai: WorkbenchAIFeatureFacade
  @StateObject var chatState: WorkbenchAIChatFeatureFacade
  @ObservedObject var operationSession: AIChatSurfaceOperationSession
  @Binding var surfaceState: AIChatSurfaceState
  @State var inspectorTransientConversationID = UUID()
  @State var latestMessageScrollTask: Task<Void, Never>?
  @State var draftDiffPreview: AIChatDraftDiffPreview?
  @State var visibleMessageLimit = 8
  @State var isFollowingLatestMessage = true
  @State var messageAnchorToPreserve: AIPublishingChatMessage.ID?
  @State var isPartialRetryConfirmationPresented = false
  @State var isDataSharingConsentConfirmationPresented = false
  @State var pendingDataSharingConsentConfig: AIProviderConfig?
  @State var pendingDataSharingConsentPresentation: AIDataSharingConsentPresentation?
  @State var isConversationPopoverPresented = false
  @State var isModelQuickSwitchPresented = false
  @State var isAdvancedSettingsExpanded = false
  @State var generalKeyAvailabilityByConnectionID: [UUID: KeychainTokenAvailability] = [:]
  @FocusState var isComposerFocused: Bool
  @State var isHeaderTitleHovered = false

  init(
    store: WorkbenchStore,
    surfaceState: Binding<AIChatSurfaceState>,
    operationSession: AIChatSurfaceOperationSession
  ) {
    ai = store.ai
    _chatState = StateObject(
      wrappedValue: WorkbenchAIChatFeatureFacade(store: store)
    )
    _operationSession = ObservedObject(wrappedValue: operationSession)
    _surfaceState = surfaceState
  }

  var body: some View {
    VStack(spacing: 0) {
      inspectorHeader

      Divider()

      if isAIKeyMissing {
        missingAIKeyBanner
        Divider()
      }

      if agentToolAvailability?.message != nil {
        agentToolsUnavailableBanner
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
    .onAppear {
      ensureInspectorSurfaceConversationSelection()
      refreshDisplayedGeneralKeyAvailability()
      synchronizeChatDraftWithSelection()
      applyPendingQuickPrompt()
      focusComposerIfAvailable()
    }
    .onDisappear {
      latestMessageScrollTask?.cancel()
      _ = operationSession.handle(
        .transientSurfaceDisappearance,
        forwardingTo: { ownerToken in
          ai.cancelChatReply(expectedOwnerToken: ownerToken)
        }
      )
    }
    .onChange(of: ai.selectedChatDraft?.id) { _, _ in
      if ai.chatContextMode != .general {
        surfaceState.selectedConversationID = nil
      }
      ensureInspectorSurfaceConversationSelection()
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
    .onChange(of: ai.chatContextMode) { _, mode in
      synchronizeInspectorConversationForContextMode(mode)
      refreshDisplayedGeneralKeyAvailability()
    }
    .onChange(of: generalKeyAvailabilityRefreshKey) { _, _ in
      refreshDisplayedGeneralKeyAvailability()
    }
    .onChange(of: ai.activeChatConversationID) { _, _ in
      if ai.chatContextMode != .general {
        synchronizeInspectorSurfaceWithActiveConversation()
      }
      visibleMessageLimit = 8
      isFollowingLatestMessage = true
    }
    .onChange(of: ai.activeGeneralChatConversationID) { _, _ in
      if ai.chatContextMode == .general {
        synchronizeInspectorSurfaceWithActiveConversation()
      }
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
        chatState: chatState,
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
    .confirmationDialog(
      String(localized: "允许发送到远程 AI？"),
      isPresented: $isDataSharingConsentConfirmationPresented,
      titleVisibility: .visible
    ) {
      if pendingDataSharingConsentConfig?.usesCodexAppServer == true {
        Button(String(localized: "前往 ChatGPT 账户设置")) {
          openCodexAccountSettingsForConsent()
        }
      } else {
        Button(String(localized: "同意并发送")) {
          grantPendingDataSharingConsentAndSubmit()
        }
      }
      Button("取消", role: .cancel) {
        clearPendingDataSharingConsent()
      }
    } message: {
      if let presentation = pendingDataSharingConsentPresentation {
        if pendingDataSharingConsentConfig?.usesCodexAppServer == true {
          Text("ChatGPT 需要先在 AI 设置中完成当前账户登录和内容发送授权；完成后返回此处再发送。")
        } else {
          Text(
            "将把本次消息及所选上下文发送到 \(presentation.providerName)（\(presentation.destination)）。同意后，该目的地后续可直接使用；你可随时在设置中撤销。"
          )
        }
      }
    }
  }
}
