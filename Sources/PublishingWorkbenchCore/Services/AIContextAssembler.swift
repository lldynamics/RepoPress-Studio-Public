import Foundation

/// Single entry point for context preview and request assembly. Callers pass
/// only the references the user selected; this type never discovers implicit
/// article/editor/repository state on its own.
public enum AIContextAssembler {
  public static func generalEnvelope(
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    explicitContextReferences: [AIContextReference] = [],
    explicitContextPrompt: String? = nil,
    knowledgeContext: KnowledgeContextSnapshot? = nil
  ) -> AIContextEnvelope {
    let privacyService = AIOutboundPayloadPrivacyService()
    return AIContextEnvelope.general(
      knowledgePolicy: knowledgePolicy,
      explicitContextReferences: explicitContextReferences,
      explicitContextPrompt: explicitContextPrompt.map { privacyService.sanitize($0).text },
      knowledgeContext: privacyService.sanitizedKnowledgeContext(knowledgeContext)
    )
  }
}
