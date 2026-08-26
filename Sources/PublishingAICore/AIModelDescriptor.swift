import Foundation

public struct AIModelDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var isReasoning: Bool
  public var isVision: Bool
  public var isChat: Bool

  public init(
    id: String,
    name: String? = nil,
    isReasoning: Bool = false,
    isVision: Bool = false,
    isChat: Bool = true
  ) {
    self.id = id
    self.name = name ?? id
    self.isReasoning = isReasoning
    self.isVision = isVision
    self.isChat = isChat
  }

  public var badgeTitle: String? {
    if isReasoning {
      return "深度思考"
    }
    if isVision {
      return "多模态"
    }
    return nil
  }
}
