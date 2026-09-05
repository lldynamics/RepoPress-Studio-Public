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
  @Environment(\.settingsWorkspaceCommandAction) var settingsWorkspaceCommandAction
  let ai: WorkbenchAIFeatureFacade
  let selectedDraftID: UUID?
  let usesWindowDraftSelection: Bool
  @StateObject var chatState: WorkbenchAIChatFeatureFacade
  @StateObject var staticProjectionCache = AIChatInspectorStaticProjectionCache()
  @ObservedObject var operationSession: AIChatSurfaceOperationSession
  @Binding var surfaceState: AIChatSurfaceState
  @State var inspectorTransientConversationID = UUID()
  @State var latestMessageScrollTask: Task<Void, Never>?
  @State var latestMessageScrollGeneration: UInt64 = 0
  /// Once the reader drags through history, streaming updates must not steal
  /// the scroll position. A newly selected conversation starts pinned again.
  @State var isPinnedToLatestMessage = true
  @State var draftDiffPreview: AIChatDraftDiffPreview?
  @State var visibleMessageLimit = 8
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
    selectedDraftID: UUID? = nil,
    usesWindowDraftSelection: Bool = false,
    surfaceState: Binding<AIChatSurfaceState>,
    operationSession: AIChatSurfaceOperationSession
  ) {
    ai = store.ai
    self.selectedDraftID = selectedDraftID
    self.usesWindowDraftSelection = usesWindowDraftSelection
    _chatState = StateObject(
      wrappedValue: WorkbenchAIChatFeatureFacade(
        store: store,
        draftID: selectedDraftID,
        windowScopedDraftSelection: usesWindowDraftSelection
      )
    )
    _operationSession = ObservedObject(wrappedValue: operationSession)
    _surfaceState = surfaceState
  }

  private var inspectorContent: some View {
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

      ScrollViewReader { proxy in
        ZStack(alignment: .bottomTrailing) {
          ScrollView {
            AIChatContextInspectorContent(state: state, actions: actions)
              .padding(16)
          }
          .defaultScrollAnchor(.bottom)
          .simultaneousGesture(
            DragGesture(minimumDistance: 2).onChanged { _ in
              latestMessageScrollGeneration &+= 1
              latestMessageScrollTask?.cancel()
              latestMessageScrollTask = nil
              isPinnedToLatestMessage = AIChatScrollPinningPolicy.isPinnedAfterUserDrag()
            }
          )
          .onAppear {
            scrollToLatestMessage(using: proxy)
          }
          .onChange(of: latestMessageID) { _, _ in
            scheduleLatestMessageScroll(
              using: proxy
            )
          }
          .onChange(of: latestMessageContent) { _, _ in
            // Stream content is already published at most every 50 ms. Scroll
            // each publication so a continuous stream cannot starve a debounce.
            scheduleLatestMessageScroll(
              using: proxy
            )
          }
          .onChange(of: visibleMessageLimit) { _, _ in
            guard let anchor = messageAnchorToPreserve else { return }
            DispatchQueue.main.async {
              proxy.scrollTo(anchor, anchor: .top)
              messageAnchorToPreserve = nil
            }
          }

          if AIChatScrollPinningPolicy.shouldShowReturnToLatest(
            isPinnedToLatest: isPinnedToLatestMessage,
            hasLatestMessage: latestMessageID != nil
          ) {
            Button {
              scrollToLatestMessage(using: proxy)
            } label: {
              Label(String(localized: "回到最新消息"), systemImage: "arrow.down.to.line")
            }
            .workbenchProminentActionStyle()
            .controlSize(.small)
            .padding(16)
            .accessibilityIdentifier("ai-chat-return-to-latest")
          }
        }
      }

      Divider()

      messageComposer
    }
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 助手")
  }

  private var inspectorLifecycleContent: some View {
    inspectorContent
      .onAppear {
        ensureInspectorSurfaceConversationSelection()
        refreshDisplayedGeneralKeyAvailability()
        synchronizeChatDraftWithSelection()
        applyPendingQuickPrompt()
        focusComposerIfAvailable()
      }
      .onChange(of: selectedDraftID) { _, draftID in
        chatState.setObservedDraftID(draftID)
        if ai.chatContextMode != .general {
          surfaceState.selectedConversationID = nil
        }
        ensureInspectorSurfaceConversationSelection()
        synchronizeChatDraftWithSelection()
      }
      .onDisappear {
        handleInspectorSurfaceDisappearance()
      }
      .onChange(of: inspectorDraft?.id) { _, _ in
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
        isPinnedToLatestMessage = true
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
        isPinnedToLatestMessage = true
      }
      .onChange(of: ai.activeGeneralChatConversationID) { _, _ in
        if ai.chatContextMode == .general {
          synchronizeInspectorSurfaceWithActiveConversation()
        }
        visibleMessageLimit = 8
        isPinnedToLatestMessage = true
      }
      .onChange(of: ai.chatMessages.count) { _, count in
        if count == 0 {
          visibleMessageLimit = 8
        }
      }
  }

  var body: some View {
    inspectorLifecycleContent
      .sheet(item: $draftDiffPreview) { preview in
        AIChatDraftDiffPreviewSheet(preview: preview) {
          applyDraftDiffPreview(preview)
        }
      }
      .sheet(isPresented: $isModelQuickSwitchPresented) {
        AIChatModelQuickSwitchSheet(
          ai: ai,
          chatState: chatState,
          draft: inspectorDraft
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

  private func handleInspectorSurfaceDisappearance() {
    latestMessageScrollTask?.cancel()
    _ = operationSession.handle(
      .transientSurfaceDisappearance,
      forwardingTo: cancelChatReply(ownerToken:)
    )
  }

  private func cancelChatReply(ownerToken: UUID) {
    ai.cancelChatReply(expectedOwnerToken: ownerToken)
  }

  var inspectorDraft: ArticleDraft? {
    AIChatInspectorDraftResolver.resolve(
      selectedDraftID: selectedDraftID,
      usesWindowDraftSelection: usesWindowDraftSelection,
      ai: ai
    )
  }
}
