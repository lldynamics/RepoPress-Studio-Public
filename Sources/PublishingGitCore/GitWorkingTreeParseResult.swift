import Foundation

/// The pure result of parsing a Git working-tree status response.
///
/// The parser deliberately leaves `lineDiff` unset. Computing a diff requires
/// repository I/O and belongs to the Workbench adapter layer.
public struct GitWorkingTreeParseResult: Hashable, Sendable {
  public var branchStatus: RepositoryBranchStatus?
  public var changedFiles: [RepositoryChangedFile]

  public init(
    branchStatus: RepositoryBranchStatus? = nil,
    changedFiles: [RepositoryChangedFile] = []
  ) {
    self.branchStatus = branchStatus
    self.changedFiles = changedFiles
  }
}
