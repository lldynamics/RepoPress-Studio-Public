import Foundation

public enum AIChatFollowUpSuggestionKind: String, Codable, Hashable, Sendable {
  case prompt
  case toolAction
}

public struct AIChatFollowUpSuggestion: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var title: String
  public var prompt: String
  public var kind: AIChatFollowUpSuggestionKind
  public var icon: String?
  public var toolCommand: WorkbenchAutomationCommandID?

  public init(
    id: UUID = UUID(),
    title: String,
    prompt: String,
    kind: AIChatFollowUpSuggestionKind = .prompt,
    icon: String? = nil,
    toolCommand: WorkbenchAutomationCommandID? = nil
  ) {
    self.id = id
    self.title = title.trimmedForPublishing
    self.prompt = prompt.trimmedForPublishing
    self.kind = kind
    self.icon = icon?.trimmedForPublishing.nilIfEmpty
    self.toolCommand = toolCommand
  }
}
