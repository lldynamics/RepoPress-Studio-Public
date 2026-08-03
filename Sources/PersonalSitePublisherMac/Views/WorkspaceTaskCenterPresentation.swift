import PublishingWorkbenchCore

enum WorkspaceTaskCenterPresentation {
  static func ordered(_ tasks: [WorkbenchTaskItem]) -> [WorkbenchTaskItem] {
    tasks.sorted { lhs, rhs in
      if lhs.state == .running, rhs.state != .running { return true }
      if lhs.state != .running, rhs.state == .running { return false }
      if lhs.kind.sortRank != rhs.kind.sortRank {
        return lhs.kind.sortRank < rhs.kind.sortRank
      }
      return lhs.id < rhs.id
    }
  }
}
