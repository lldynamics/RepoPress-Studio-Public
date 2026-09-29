import Foundation

public enum AIAgentRetirement {
  public static var message: String {
    CoreL10n.text("旧版 Agent 已退役。这条记录仅供查看；请从写作工具重新发起任务。")
  }
}

extension AIPublishingChatMessage {
  public var isRetiredAgentRecord: Bool {
    automationPlan?.source == .agentLoop || agentContinuation != nil
  }
}
