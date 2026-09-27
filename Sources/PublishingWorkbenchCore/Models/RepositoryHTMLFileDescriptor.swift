import Foundation

public struct RepositoryHTMLFileDescriptor: Identifiable, Hashable, Sendable {
  public var id: String { repositoryPath }
  public var repositoryPath: String
  public var byteSize: Int
  public var modificationDate: Date?

  public init(
    repositoryPath: String,
    byteSize: Int,
    modificationDate: Date?
  ) {
    self.repositoryPath = repositoryPath
    self.byteSize = byteSize
    self.modificationDate = modificationDate
  }
}
