import Foundation

// MARK: - Shared publishing helpers
extension RemoteRepositoryPublishService {
  func unwrapContentData(_ data: Data?, for file: PublishPackageFile) throws -> Data {
    guard let data else {
      throw RemoteRepositoryPublishError.invalidSourceFile(
        path: file.repositoryPath,
        reason: "无法准备发布内容。"
      )
    }
    return data
  }
}
