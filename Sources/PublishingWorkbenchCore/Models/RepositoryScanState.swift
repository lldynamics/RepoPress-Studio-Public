import Foundation

public struct RepositoryScanState: Codable, Hashable, Sendable {
  public var isScanning: Bool
  public var message: String
  public var startedAt: Date?
  public var finishedAt: Date?

  public init(
    isScanning: Bool = false,
    message: String? = nil,
    startedAt: Date? = nil,
    finishedAt: Date? = nil
  ) {
    self.isScanning = isScanning
    self.message = message ?? CoreL10n.text("未扫描")
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  public static var idle: RepositoryScanState {
    RepositoryScanState()
  }

  public static func scanning(startedAt: Date = Date()) -> RepositoryScanState {
    RepositoryScanState(
      isScanning: true,
      message: CoreL10n.text("正在扫描仓库..."),
      startedAt: startedAt
    )
  }

  public static func finished(report: RepositoryScanReport, finishedAt: Date = Date()) -> RepositoryScanState {
    RepositoryScanState(
      isScanning: false,
      message: CoreL10n.format(
        "扫描完成：%@ 个本地变更，%@ 个远端变更。",
        String(report.changedFiles.count),
        String(report.remoteChangedFiles.count)
      ),
      startedAt: nil,
      finishedAt: finishedAt
    )
  }

  public static func cancelled(finishedAt: Date = Date()) -> RepositoryScanState {
    RepositoryScanState(
      isScanning: false,
      message: CoreL10n.text("仓库扫描已取消。"),
      startedAt: nil,
      finishedAt: finishedAt
    )
  }
}
