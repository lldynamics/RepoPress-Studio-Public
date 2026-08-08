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
    AIContextEnvelope.general(
      knowledgePolicy: knowledgePolicy,
      explicitContextReferences: explicitContextReferences,
      explicitContextPrompt: explicitContextPrompt,
      knowledgeContext: knowledgeContext
    )
  }
}
