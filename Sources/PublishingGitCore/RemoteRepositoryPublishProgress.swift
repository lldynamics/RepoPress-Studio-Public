import Foundation
import PublishingCoreSupport

public enum RemoteRepositoryPublishProgressStage: String, Codable, Sendable {
  case preparing
  case validatingTarget
  case creatingBranch
  case uploadingFiles
  case creatingReview
  case completed
  case failed

  public var displayName: String {
    switch self {
    case .preparing:
      return CoreL10n.text("准备")
    case .validatingTarget:
      return CoreL10n.text("校验")
    case .creatingBranch:
      return CoreL10n.text("分支")
    case .uploadingFiles:
      return CoreL10n.text("上传")
    case .creatingReview:
      return CoreL10n.text("提交评审")
    case .completed:
      return CoreL10n.text("完成")
    case .failed:
      return CoreL10n.text("失败")
    }
  }
}

public struct RemoteRepositoryPublishProgress: Codable, Hashable, Sendable {
  public var stage: RemoteRepositoryPublishProgressStage
  public var progress: Double?
  public var message: String
  public var detail: String?
  public var filePath: String?
  /// Bytes from the publish package that have completed processing. This is
  /// source-content progress, not a credential-bearing network payload size.
  public var completedByteCount: Int64?
  /// Total source-content bytes represented by the publish package.
  public var totalByteCount: Int64?

  public init(
    stage: RemoteRepositoryPublishProgressStage,
    progress: Double? = nil,
    message: String,
    detail: String? = nil,
    filePath: String? = nil,
    completedByteCount: Int64? = nil,
    totalByteCount: Int64? = nil
  ) {
    self.stage = stage
    self.progress = progress
    self.message = message
    self.detail = detail
    self.filePath = filePath
    self.completedByteCount = completedByteCount
    self.totalByteCount = totalByteCount
  }

  private enum CodingKeys: String, CodingKey {
    case stage
    case progress
    case message
    case detail
    case filePath
    case completedByteCount
    case totalByteCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    stage = try container.decode(RemoteRepositoryPublishProgressStage.self, forKey: .stage)
    progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    message = try container.decode(String.self, forKey: .message)
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
    filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
    completedByteCount = try container.decodeIfPresent(Int64.self, forKey: .completedByteCount)
    totalByteCount = try container.decodeIfPresent(Int64.self, forKey: .totalByteCount)
  }

  public var byteProgress: Double? {
    guard let completedByteCount,
      let totalByteCount,
      totalByteCount > 0
    else {
      return nil
    }
    return min(1, max(0, Double(completedByteCount) / Double(totalByteCount)))
  }

  public var byteProgressDescription: String? {
    guard let byteProgress,
      let completedByteCount,
      let totalByteCount
    else {
      return nil
    }
    let percentage = Int((byteProgress * 100).rounded())
    return
      "\(Self.formatByteCount(completedByteCount)) / \(Self.formatByteCount(totalByteCount)) (\(percentage)%)"
  }

  public var statusDescription: String {
    [
      message.nilIfEmpty,
      detail?.nilIfEmpty,
      byteProgressDescription.map { CoreL10n.format("已上传 %@", $0) },
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private static func formatByteCount(_ byteCount: Int64) -> String {
    let value = Double(max(0, byteCount))
    let units = ["B", "KB", "MB", "GB", "TB"]
    guard value >= 1_000 else {
      return "\(max(0, byteCount)) B"
    }

    let exponent = min(
      units.count - 1,
      Int(log(value) / log(1_000))
    )
    let scaledValue = value / pow(1_000, Double(exponent))
    let format = scaledValue >= 100 ? "%.0f" : scaledValue >= 10 ? "%.1f" : "%.2f"
    let number = String(
      format: format,
      locale: Locale(identifier: "en_US_POSIX"),
      scaledValue
    )
    return "\(number) \(units[exponent])"
  }
}
