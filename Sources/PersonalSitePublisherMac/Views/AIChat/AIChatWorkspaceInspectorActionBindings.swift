import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension AIChatContextInspectorView {
  var actions: AIChatContextInspectorActions {
    AIChatContextInspectorActions(
      sendMessage: { message, draft in sendMessage(message, draft: draft) },
      selectDraft: { draftID in ai.selectChatDraft(draftID) },
      appendReply: { message, draft in append(message, to: draft) },
      applyCodeBlock: { block, draft in
        guard let windowID = workspaceWindowSession?.windowID else { return }
        _ = ai.applyChatMarkdown(
          block.fencedMarkdown, to: draft, mode: .applyToCurrentEditor,
          originatingWindowID: windowID
        )
      },
      insertCodeBlockAtCursor: { block, draft in
        guard let windowID = workspaceWindowSession?.windowID else { return }
        _ = ai.applyChatMarkdown(
          block.fencedMarkdown, to: draft, mode: .insertAtCursor,
          originatingWindowID: windowID
        )
      },
      copyCodeBlock: { block in
        _ = ClipboardWriter.copy(
          block.fencedMarkdown, successMessage: String(localized: "已复制完整 Markdown 代码块。"),
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
      loadEarlierMessages: { loadEarlierMessages() },
      openCitation: { citation in _ = ai.openKnowledgeCitation(citation) },
      previewStructuredEdits: { message, review, draft in
        guard inspectorDraft?.id == draft.id else { return }
        _ = ai.beginInlineStructuredEditReview(message: message, review: review)
      },
      recordStructuredEditFeedback: { decision, proposal, model in
        ai.recordStructuredEditFeedback(decision, proposal: proposal, model: model)
      },
      createTranslationDraft: { plan in _ = ai.createLinkedTranslationDraft(from: plan) },
      executeAutomationPlan: { conversationID, messageID in
        Task {
          _ = await ai.executeAutomationPlan(conversationID: conversationID, messageID: messageID)
        }
      },
      executeAutomationStep: { conversationID, messageID, stepID in
        Task {
          _ = await ai.executeAutomationPlan(
            conversationID: conversationID, messageID: messageID, onlyStepID: stepID,
            confirmedStepIDs: [stepID]
          )
        }
      },
      acceptAutomationStep: { conversationID, messageID, stepID, baseline in
        Task {
          _ = await ai.acceptAutomationStep(
            conversationID: conversationID, messageID: messageID, stepID: stepID,
            previewBaselineFingerprint: baseline
          )
        }
      },
      rejectAutomationStep: { conversationID, messageID, stepID, baseline in
        Task {
          _ = await ai.rejectAutomationStep(
            conversationID: conversationID, messageID: messageID, stepID: stepID,
            previewBaselineFingerprint: baseline
          )
        }
      },
      previewAutomationStep: { conversationID, messageID, stepID in
        ai.automationDraftPreview(
          conversationID: conversationID, messageID: messageID, stepID: stepID)
      },
      cancelAutomationPlan: { conversationID, messageID in
        ai.cancelAutomationPlan(conversationID: conversationID, messageID: messageID)
      },
      rollbackAutomationRun: { recordID in _ = ai.rollbackAutomationRun(recordID) },
      abandonAgentContinuation: {
        conversationID, messageID, planID, continuationID, expectedRevision in
        ai.abandonAgentContinuation(
          conversationID: conversationID, messageID: messageID, planID: planID,
          continuationID: continuationID, expectedRevision: expectedRevision
        )
      }
    )
  }
}
