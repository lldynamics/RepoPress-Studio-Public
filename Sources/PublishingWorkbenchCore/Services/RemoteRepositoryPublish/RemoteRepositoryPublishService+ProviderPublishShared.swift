import Foundation

// MARK: - Shared publishing helpers
extension RemoteRepositoryPublishService {
  func normalizedPublishPackage(_ package: PublishPackage) throws -> PublishPackage {
    var normalizedPackage = package
    var seenPaths = Set<String>()

    normalizedPackage.files = try package.files.map { file in
      let path = file.repositoryPath.normalizedRelativePath()
      guard !path.isEmpty else {
        throw RemoteRepositoryPublishError.invalidRepositoryPath(
          path: file.repositoryPath,
          reason: CoreL10n.text("路径规范化后为空；已在任何远端请求前阻止发布。")
        )
      }
      guard seenPaths.insert(path).inserted else {
        throw RemoteRepositoryPublishError.invalidRepositoryPath(
          path: path,
          reason: CoreL10n.text("发布包包含重复路径；已在任何远端请求前阻止发布。")
        )
      }

      var normalizedFile = file
      normalizedFile.repositoryPath = path
      return normalizedFile
    }
    normalizedPackage.markdownPath = package.markdownPath.normalizedRelativePath()
    return normalizedPackage
  }

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
