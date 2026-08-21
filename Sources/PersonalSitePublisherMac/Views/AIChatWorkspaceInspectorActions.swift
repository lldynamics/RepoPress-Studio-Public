import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension AIChatContextInspectorView {

  var state: AIChatContextInspectorState {
    guard let draft = ai.selectedChatDraft else {
      return AIChatContextInspectorState(draft: nil)
    }

    let profile = ai.chatContextMode == .general ? nil : ai.chatProfile(for: draft)
    let relationSuggestions =
      ai.chatContextMode == .general
      ? []
      : ai.relatedChatArticleSuggestions(for: draft, limit: 5)
    let displayedGeneralConversation =
      ai.chatContextMode == .general
      ? ai.generalChatConversation(withID: inspectorSurfaceConversationID)
      : nil
    let displayedMessages =
      ai.chatContextMode == .general
      ? (displayedGeneralConversation?.messages ?? [])
      : ai.chatMessages
    let displayedConversationID =
      ai.chatContextMode == .general
      ? displayedGeneralConversation?.id
      : ai.activeChatConversationID(for: draft.id)
    let displayedConversationTitle: String
    if ai.chatContextMode == .general {
      if let title = displayedGeneralConversation?.title?.trimmedForPublishing.nilIfEmpty {
        displayedConversationTitle = title
      } else if let firstUserMessage = displayedMessages.first(where: { $0.role == .user }) {
        displayedConversationTitle = AIPublishingChatConversationPresentation.title(
          fromUserText: AIPublishingChatMessageCompositionService.displayContent(
            for: firstUserMessage),
          fallbackTitle: String(localized: "通用 AI 对话")
        )
      } else {
        displayedConversationTitle = String(localized: "通用 AI 对话")
      }
    } else {
      displayedConversationTitle = AIPublishingChatConversationPresentation.displayTitle(
        conversationTitle: ai.chatConversationTitle,
        messages: displayedMessages,
        draft: draft,
        emptyTitle: String(localized: "AI 对话")
      )
    }

    return AIChatContextInspectorState(
      draft: AIChatInspectorDraftContext(
        draft: draft,
        conversationID: displayedConversationID,
        conversationTitle: displayedConversationTitle,
        messages: Array(displayedMessages.suffix(visibleMessageLimit)),
        totalMessageCount: displayedMessages.count,
        relatedSuggestions: relationSuggestions.prefix(4).map { suggestion in
          AIChatRelatedSuggestionPresentation(
            id: suggestion.id,
            targetTitle: suggestion.targetTitle,
            reason: suggestion.reason,
            targetPath: suggestion.targetPath,
            targetDraftID: suggestion.targetDraftID,
            prompt: profile.map {
              AIPublishingChatPromptTemplateService.relatedArticleSuggestionPrompt(
                for: suggestion,
                draft: draft,
                profile: $0
              )
            } ?? ""
          )
        },
        isChatRunning: ai.isChatRunning,
        isAutomationRunning: ai.isAutomationRunning,
        automationRunRecords: ai.automationRunRecords
      )
    )
  }

  var actions: AIChatContextInspectorActions {
    AIChatContextInspectorActions(
      sendMessage: { message, draft in
        sendMessage(message, draft: draft)
      },
      selectDraft: { draftID in
        ai.selectChatDraft(draftID)
      },
      appendReply: { message, draft in
        append(message, to: draft)
      },
      applyCodeBlock: { block, draft in
        _ = ai.applyChatMarkdown(
          block.fencedMarkdown,
          to: draft,
          mode: .applyToCurrentEditor
        )
      },
      insertCodeBlockAtCursor: { block, draft in
        _ = ai.applyChatMarkdown(
          block.fencedMarkdown,
          to: draft,
          mode: .insertAtCursor
        )
      },
      copyCodeBlock: { block in
        _ = ClipboardWriter.copy(
          block.fencedMarkdown,
          successMessage: String(localized: "已复制完整 Markdown 代码块。"),
          setMessage: { message in ai.setChatMessage(message) }
        )
      },
      copyReply: { message in
        _ = ClipboardWriter.copy(
          AIPublishingChatMessageCompositionService.displayContent(for: message),
          successMessage: String(localized: "已复制到剪贴板。"),
          setMessage: { status in ai.setChatMessage(status) }
        )
      },
      branchConversation: { messageID, draft in
        _ = ai.branchChatConversation(after: messageID, draft: draft)
      },
      loadEarlierMessages: {
        loadEarlierMessages()
      },
      openCitation: { citation in
        _ = ai.openKnowledgeCitation(citation)
      },
      previewStructuredEdits: { message, review, draft in
        guard
          let current = ai.selectedChatDraft,
          current.id == draft.id,
          let updated = ai.reviewedStructuredEditDraft(
            message: message,
            review: review
          )
        else {
          return
        }
        draftDiffPreview = AIChatDraftDiffPreview(
          originalDraft: current,
          updatedDraft: updated,
          citations: [],
          applicationKind: .structuredEdit
        )
      },
      recordStructuredEditFeedback: { decision, proposal, model in
        ai.recordStructuredEditFeedback(
          decision,
          proposal: proposal,
          model: model
        )
      },
      createTranslationDraft: { plan in
        _ = ai.createLinkedTranslationDraft(from: plan)
      },
      localFeedbackDecision: { message in
        ai.localFeedbackDecision(for: message)
      },
      recordLocalFeedback: { decision, message in
        ai.recordLocalFeedback(decision, for: message)
      },
      executeAutomationPlan: { conversationID, messageID in
        Task {
          _ = await ai.executeAutomationPlan(
            conversationID: conversationID,
            messageID: messageID
          )
        }
      },
      executeAutomationStep: { conversationID, messageID, stepID in
        Task {
          _ = await ai.executeAutomationPlan(
            conversationID: conversationID,
            messageID: messageID,
            onlyStepID: stepID,
            confirmedStepIDs: Set([stepID])
          )
        }
      },
      acceptAutomationStep: { conversationID, messageID, stepID, baseline in
        Task {
          _ = await ai.acceptAutomationStep(
            conversationID: conversationID,
            messageID: messageID,
            stepID: stepID,
            previewBaselineFingerprint: baseline
          )
        }
      },
      rejectAutomationStep: { conversationID, messageID, stepID, baseline in
        Task {
          _ = await ai.rejectAutomationStep(
            conversationID: conversationID,
            messageID: messageID,
            stepID: stepID,
            previewBaselineFingerprint: baseline
          )
        }
      },
      previewAutomationStep: { conversationID, messageID, stepID in
        ai.automationDraftPreview(
          conversationID: conversationID,
          messageID: messageID,
          stepID: stepID
        )
      },
      cancelAutomationPlan: { conversationID, messageID in
        ai.cancelAutomationPlan(
          conversationID: conversationID,
          messageID: messageID
        )
      },
      rollbackAutomationRun: { recordID in
        _ = ai.rollbackAutomationRun(recordID)
      },
      abandonAgentContinuation: {
        conversationID,
        messageID,
        planID,
        continuationID,
        expectedRevision in
        ai.abandonAgentContinuation(
          conversationID: conversationID,
          messageID: messageID,
          planID: planID,
          continuationID: continuationID,
          expectedRevision: expectedRevision
        )
      }
    )
  }

  func sendMessage(_ message: String, draft: ArticleDraft) {
    startSending(message, draft: draft, clearsComposerOnAccept: false)
  }

  var latestMessageID: AIPublishingChatMessage.ID? {
    state.draft?.messages.last?.id
  }

  var latestMessageContent: String {
    state.draft?.messages.last?.content ?? ""
  }

  func startSending(
    _ message: String,
    draft: ArticleDraft,
    clearsComposerOnAccept: Bool
  ) {
    guard
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: sendTask != nil,
        globalOperationRunning: ai.isChatRunning
      )
    else { return }
    isFollowingLatestMessage = true
    let ownerToken = UUID()
    let submittedSurfaceConversationID = inspectorSurfaceConversationID
    let existingMessageIDs = Set(
      (ai.chatContextMode == .general
        ? ai.generalChatConversation(withID: submittedSurfaceConversationID)?.messages ?? []
        : ai.chatMessages).map(\.id)
    )
    let requestedImageAttachmentIDs = selectedImageAttachmentIDs
    let requestedContextReferences = selectedContextReferences
    isSubmitting = true
    activeSendOwnerToken = ownerToken
    sendTask = Task {
      defer {
        if activeSendOwnerToken == ownerToken {
          isSubmitting = false
          sendTask = nil
          activeSendOwnerToken = nil
        }
      }
      let imageAttachments = await ai.chatImageAttachments(
        for: draft,
        attachmentIDs: requestedImageAttachmentIDs
      )
      guard !Task.isCancelled else {
        return
      }
      let reply: AIPublishingChatMessage?
      if ai.chatContextMode == .general {
        let generalConversationID = ai.generalChatConversation(
          withID: submittedSurfaceConversationID
        )?.id
        reply = await ai.sendGeneralChatMessage(
          message,
          conversationID: generalConversationID,
          connectionProfileID: ai.generalChatConversation(
            withID: submittedSurfaceConversationID
          )?.connectionProfileID,
          imageAttachments: imageAttachments,
          contextReferences: requestedContextReferences,
          ownerToken: ownerToken
        )
      } else {
        reply = await ai.sendChatMessage(
          message,
          draft: draft,
          imageAttachments: imageAttachments,
          contextReferences: requestedContextReferences,
          ownerToken: ownerToken
        )
      }
      let currentMessages: [AIPublishingChatMessage]
      if ai.chatContextMode == .general {
        currentMessages =
          ai.generalChatConversation(
            withID: submittedSurfaceConversationID
          )?.messages
          ?? ai.activeGeneralChatConversation?.messages
          ?? []
      } else {
        currentMessages = ai.chatMessages
      }
      let didAcceptUserMessage = currentMessages.contains {
        !existingMessageIDs.contains($0.id) && $0.role == .user
      }
      if clearsComposerOnAccept,
        reply != nil || didAcceptUserMessage,
        surfaceState.composerText(for: submittedSurfaceConversationID)
          .trimmingCharacters(in: .whitespacesAndNewlines) == message
      {
        updateInspectorSurfaceState { state in
          state.setComposerText("", for: submittedSurfaceConversationID)
        }
        if surfaceState.imageAttachmentIDs(for: submittedSurfaceConversationID)
          == requestedImageAttachmentIDs
        {
          updateInspectorSurfaceState { state in
            state.setImageAttachmentIDs([], for: submittedSurfaceConversationID)
          }
        }
        if surfaceState.contextReferences(for: submittedSurfaceConversationID)
          == requestedContextReferences
        {
          updateInspectorSurfaceState { state in
            state.setContextReferences([], for: submittedSurfaceConversationID)
          }
        }
      }
      if ai.chatContextMode == .general,
        let activeConversationID = ai.activeGeneralChatConversationID
      {
        setInspectorSurfaceConversationID(activeConversationID)
      }
    }
  }

  func stopSending() {
    guard
      AIChatSurfaceOperationOwnershipPolicy.canCancelLocalOperation(
        localTaskExists: sendTask != nil,
        ownerToken: activeSendOwnerToken
      )
    else {
      return
    }
    guard let ownerToken = activeSendOwnerToken else { return }
    sendTask?.cancel()
    ai.cancelChatReply(expectedOwnerToken: ownerToken)
  }

  func retryLastFailedReply(confirmingPossibleDuplicateCharge: Bool) {
    guard
      AIChatSurfaceOperationOwnershipPolicy.canStartLocalOperation(
        localTaskExists: sendTask != nil,
        globalOperationRunning: ai.isChatRunning
      )
    else { return }
    isFollowingLatestMessage = true
    isSubmitting = true
    let ownerToken = UUID()
    activeSendOwnerToken = ownerToken
    sendTask = Task {
      defer {
        if activeSendOwnerToken == ownerToken {
          isSubmitting = false
          sendTask = nil
          activeSendOwnerToken = nil
        }
      }
      if ai.chatContextMode == .general {
        _ = await ai.retryLastFailedGeneralChatReply(
          confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
          conversationID: inspectorSurfaceConversationID,
          ownerToken: ownerToken
        )
      } else if let draft = ai.selectedChatDraft {
        _ = await ai.retryLastFailedChatReply(
          confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
          draft: draft,
          ownerToken: ownerToken
        )
      }
    }
  }

  func loadEarlierMessages() {
    guard let context = state.draft,
      context.totalMessageCount > context.messages.count
    else { return }
    messageAnchorToPreserve = context.messages.first?.id
    visibleMessageLimit = min(context.totalMessageCount, visibleMessageLimit + 8)
  }

  func applyPendingQuickPrompt() {
    guard let prompt = ai.consumePendingQuickPrompt() else { return }
    if trimmedInput.isEmpty {
      setInputText(prompt.prompt)
    } else if trimmedInput != prompt.prompt {
      setInputText("\(inputText)\n\n\(prompt.prompt)")
    }
    focusComposerIfAvailable()
  }

  func focusComposerIfAvailable() {
    guard ai.chatContextMode == .general || ai.selectedChatDraft != nil, !isChatBusy else {
      return
    }
    DispatchQueue.main.async {
      isComposerFocused = true
    }
  }

  func synchronizeChatDraftWithSelection() {
    guard let draft = ai.selectedChatDraft,
      ai.chatDraftID != draft.id
    else { return }
    ai.prepareChat(for: draft)
  }

  func scrollToLatestMessage(
    using proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    guard let latestMessageID else { return }
    DispatchQueue.main.async {
      if animated {
        withAnimation(WorkbenchMotion.standard) {
          proxy.scrollTo(latestMessageID, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(latestMessageID, anchor: .bottom)
      }
    }
  }

  func scheduleLatestMessageScroll(
    using proxy: ScrollViewProxy,
    animated: Bool,
    delayNanoseconds: UInt64 = 0
  ) {
    latestMessageScrollTask?.cancel()
    let targetID = latestMessageID
    latestMessageScrollTask = Task { @MainActor in
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
      guard !Task.isCancelled,
        isFollowingLatestMessage,
        let targetID
      else { return }
      if animated {
        withAnimation(WorkbenchMotion.standard) {
          proxy.scrollTo(targetID, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(targetID, anchor: .bottom)
      }
      latestMessageScrollTask = nil
    }
  }

  func append(_ message: AIPublishingChatMessage, to draft: ArticleDraft) {
    let content = KnowledgeCitationMarkdownService.appendingCitations(
      to: message.content,
      citations: message.knowledgeCitations
    )
    guard
      let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
        content,
        to: draft,
        mode: .appendToBody
      )
    else {
      ai.setChatMessage(String(localized: "AI 回复为空，未应用。"))
      return
    }

    draftDiffPreview = AIChatDraftDiffPreview(
      originalDraft: draft,
      updatedDraft: result.draft,
      citations: message.knowledgeCitations
    )
    ai.setChatMessage(
      String(localized: "AI 修改预览已打开，接受后才会写入文章。")
    )
  }

  func applyDraftDiffPreview(_ preview: AIChatDraftDiffPreview) {
    guard let current = ai.selectedChatDraft,
      AIChatDraftDiffApplicationPolicy.canApply(
        currentDraft: current,
        preview: preview
      )
    else {
      ai.setChatMessage(
        String(localized: "文章已变化，这份 AI 修改预览未应用；请重新预览。")
      )
      return
    }
    ai.updateChatDraft(preview.updatedDraft)
    ai.saveChatDraftChanges()
    ai.recordKnowledgeBacklinks(
      preview.citations,
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: preview.updatedDraft.id.uuidString,
        title: preview.updatedDraft.title,
        location: "正文"
      )
    )
    ai.setChatMessage(
      applicationSuccessMessage(for: preview)
    )
  }

  func applicationSuccessMessage(
    for preview: AIChatDraftDiffPreview
  ) -> String {
    if preview.citationCount > 0 {
      return String(localized: "已追加 AI 回复并插入资料库脚注。")
    }
    switch preview.applicationKind {
    case .appendedReply:
      return String(localized: "已接受 AI 修改并追加到文章末尾。")
    case .structuredEdit:
      return String(localized: "已接受所选 AI 修改。")
    }
  }
}
