import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension AIChatContextInspectorView {

  var state: AIChatContextInspectorState {
    guard let draft = ai.selectedChatDraft else {
      return AIChatContextInspectorState(draft: nil)
    }

    let profile = ai.chatProfile(for: draft)
    let relationSuggestions = ai.relatedChatArticleSuggestions(for: draft, limit: 5)

    return AIChatContextInspectorState(
      draft: AIChatInspectorDraftContext(
        draft: draft,
        conversationTitle: AIPublishingChatConversationPresentation.displayTitle(
          conversationTitle: ai.chatConversationTitle,
          messages: ai.chatMessages,
          draft: draft,
          emptyTitle: String(localized: "AI 对话")
        ),
        messages: ai.chatDraftID == draft.id
          ? Array(ai.chatMessages.suffix(visibleMessageLimit)) : [],
        totalMessageCount: ai.chatDraftID == draft.id ? ai.chatMessages.count : 0,
        relatedSuggestions: relationSuggestions.prefix(4).map { suggestion in
          AIChatRelatedSuggestionPresentation(
            id: suggestion.id,
            targetTitle: suggestion.targetTitle,
            reason: suggestion.reason,
            targetPath: suggestion.targetPath,
            targetDraftID: suggestion.targetDraftID,
            prompt: AIPublishingChatPromptTemplateService.relatedArticleSuggestionPrompt(
              for: suggestion,
              draft: draft,
              profile: profile
            )
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
      executeAutomationPlan: { messageID in
        Task {
          _ = await ai.executeAutomationPlan(messageID: messageID)
        }
      },
      executeAutomationStep: { messageID, stepID in
        Task {
          _ = await ai.executeAutomationPlan(
            messageID: messageID,
            onlyStepID: stepID,
            confirmedStepIDs: Set([stepID])
          )
        }
      },
      previewAutomationStep: { messageID, stepID in
        ai.automationDraftPreview(messageID: messageID, stepID: stepID)
      },
      cancelAutomationPlan: { messageID in
        ai.cancelAutomationPlan(messageID: messageID)
      },
      rollbackAutomationRun: { recordID in
        _ = ai.rollbackAutomationRun(recordID)
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
    guard !isSending else { return }
    isFollowingLatestMessage = true
    let existingMessageIDs = Set(ai.chatMessages.map(\.id))
    let requestedImageAttachmentIDs = selectedImageAttachmentIDs
    let requestedContextReferences = selectedContextReferences
    isSubmitting = true
    sendTask = Task {
      let imageAttachments = await ai.chatImageAttachments(
        for: draft,
        attachmentIDs: requestedImageAttachmentIDs
      )
      guard !Task.isCancelled else {
        isSubmitting = false
        sendTask = nil
        return
      }
      let reply = await ai.sendChatMessage(
        message,
        draft: draft,
        imageAttachments: imageAttachments,
        contextReferences: requestedContextReferences
      )
      let didAcceptUserMessage = ai.chatMessages.contains {
        !existingMessageIDs.contains($0.id) && $0.role == .user
      }
      if clearsComposerOnAccept,
        reply != nil || didAcceptUserMessage,
        trimmedInput == message
      {
        inputText = ""
        if selectedImageAttachmentIDs == requestedImageAttachmentIDs {
          selectedImageAttachmentIDs = []
        }
        if selectedContextReferences == requestedContextReferences {
          selectedContextReferences = []
        }
      }
      isSubmitting = false
      sendTask = nil
    }
  }

  func stopSending() {
    sendTask?.cancel()
    sendTask = nil
    if ai.isChatRunning {
      ai.cancelChatReply()
    }
    isSubmitting = false
  }

  func retryLastFailedReply(confirmingPossibleDuplicateCharge: Bool) {
    guard let draft = ai.selectedChatDraft, !isSending else { return }
    isFollowingLatestMessage = true
    isSubmitting = true
    sendTask = Task {
      _ = await ai.retryLastFailedChatReply(
        confirmingPossibleDuplicateCharge: confirmingPossibleDuplicateCharge,
        draft: draft
      )
      isSubmitting = false
      sendTask = nil
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
      inputText = prompt.prompt
    } else if trimmedInput != prompt.prompt {
      inputText += "\n\n\(prompt.prompt)"
    }
    focusComposerIfAvailable()
  }

  func focusComposerIfAvailable() {
    guard ai.selectedChatDraft != nil, !isSending else { return }
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
