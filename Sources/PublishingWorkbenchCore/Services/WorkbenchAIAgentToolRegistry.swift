import Foundation

/// Stable identities of the built-in Workbench tools. Retired Agent records and
/// fixed automation plans still carry these IDs, so the mapping outlives the
/// removed Agent loop.
public enum WorkbenchAutomationAgentToolRegistry {
  public static let builtInCatalogRevision = "workbench-builtins-v1"

  public static func toolID(
    for command: WorkbenchAutomationCommandID
  ) -> AIAgentToolID {
    AIAgentToolID("workbench/\(command.rawValue)")
  }

  public static func command(
    for toolID: AIAgentToolID
  ) -> WorkbenchAutomationCommandID? {
    let prefix = "workbench/"
    guard toolID.rawValue.hasPrefix(prefix) else { return nil }
    let rawValue = String(toolID.rawValue.dropFirst(prefix.count))
    guard let command = WorkbenchAutomationCommandID(rawValue: rawValue),
      Self.toolID(for: command) == toolID
    else {
      return nil
    }
    return command
  }
}
