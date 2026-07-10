import Foundation

public struct RepositoryScanState: Codable, Hashable, Sendable {
  public var isScanning: Bool
  public var message: String
  public var startedAt: Date?
  public var finishedAt: Date?

  public init(
    isScanning: Bool = false,
    message: String = "未扫描",
    startedAt: Date? = nil,
    finishedAt: Date? = nil
  ) {
    self.isScanning = isScanning
    self.message = message
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  public static var idle: RepositoryScanState {
    RepositoryScanState()
  }

  public static func scanning(startedAt: Date = Date()) -> RepositoryScanState {
    RepositoryScanState(isScanning: true, message: "正在扫描仓库...", startedAt: startedAt)
  }

  public static func finished(report: RepositoryScanReport, finishedAt: Date = Date()) -> RepositoryScanState {
    RepositoryScanState(
      isScanning: false,
      message: "扫描完成：\(report.changedFiles.count) 个本地变更，\(report.remoteChangedFiles.count) 个远端变更。",
      startedAt: nil,
      finishedAt: finishedAt
    )
  }

  public static func cancelled(finishedAt: Date = Date()) -> RepositoryScanState {
    RepositoryScanState(isScanning: false, message: "仓库扫描已取消。", startedAt: nil, finishedAt: finishedAt)
  }
}
