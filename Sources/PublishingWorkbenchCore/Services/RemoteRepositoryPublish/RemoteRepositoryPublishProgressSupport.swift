import Foundation

extension RemoteRepositoryPublishService {
  func uploadByteSizes(for package: PublishPackage) -> [Int64] {
    package.files.map(uploadByteSize(for:))
  }

  func uploadByteSize(for file: PublishPackageFile) -> Int64 {
    guard file.operation == .upsert else { return 0 }
    if file.byteSize > 0 {
      return file.byteSize
    }
    if let content = file.content {
      return Int64(content.utf8.count)
    }
    if let sourceFilePath = file.sourceFilePath,
       let attributes = try? FileManager.default.attributesOfItem(atPath: sourceFilePath),
       let fileSize = attributes[.size] as? NSNumber {
      return max(0, fileSize.int64Value)
    }
    return 0
  }

  func totalUploadByteCount(for package: PublishPackage) -> Int64? {
    let total = uploadByteSizes(for: package).reduce(0, +)
    return total > 0 ? total : nil
  }

  func uploadProgressValue(
    completedByteCount: Int64,
    totalByteCount: Int64?,
    stageStart: Double,
    stageEnd: Double,
    fallback: Double
  ) -> Double {
    guard let totalByteCount, totalByteCount > 0 else {
      return fallback
    }
    let fraction = min(
      1,
      max(0, Double(completedByteCount) / Double(totalByteCount))
    )
    return stageStart + (stageEnd - stageStart) * fraction
  }

  func uploadProgressMessage(for file: PublishPackageFile, fallback: String) -> String {
    switch file.kind {
    case .image:
      return CoreL10n.text("推送图片资产")
    case .video:
      return CoreL10n.text("推送视频资产")
    case .markdown:
      return fallback
    }
  }
}
