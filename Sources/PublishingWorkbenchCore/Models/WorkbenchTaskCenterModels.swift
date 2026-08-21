import Foundation

public enum WorkbenchTaskKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case aiRequest
  case knowledgeImport
  case imageProcessing
  case siteScan
  case gitPush
  case deployment

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .aiRequest:
      return CoreL10n.text("AI 请求")
    case .knowledgeImport:
      return CoreL10n.text("资料导入")
    case .imageProcessing:
      return CoreL10n.text("图片处理")
    case .siteScan:
      return CoreL10n.text("站点扫描")
    case .gitPush:
      return CoreL10n.text("Git 推送")
    case .deployment:
      return CoreL10n.text("部署")
    }
  }

  public var systemImage: String {
    switch self {
    case .aiRequest:
      return "sparkles"
    case .knowledgeImport:
      return "books.vertical"
    case .imageProcessing:
      return "photo.on.rectangle.angled"
    case .siteScan:
      return "magnifyingglass.circle"
    case .gitPush:
      return "arrow.up.circle"
    case .deployment:
      return "shippingbox"
    }
  }

  public var sortRank: Int {
    switch self {
    case .aiRequest: return 0
    case .knowledgeImport: return 1
    case .imageProcessing: return 2
    case .siteScan: return 3
    case .gitPush: return 4
    case .deployment: return 5
    }
  }
}

public enum WorkbenchTaskState: String, Codable, Hashable, Sendable {
  case running
  case failed
  case completed
  case cancelled

  public var title: String {
    switch self {
    case .running:
      return CoreL10n.text("进行中")
    case .failed:
      return CoreL10n.text("失败")
    case .completed:
      return CoreL10n.text("已完成")
    case .cancelled:
      return CoreL10n.text("已停止")
    }
  }

  public var systemImage: String {
    switch self {
    case .running:
      return "progress.indicator"
    case .failed:
      return "exclamationmark.triangle.fill"
    case .completed:
      return "checkmark.circle.fill"
    case .cancelled:
      return "stop.circle"
    }
  }
}

public struct WorkbenchTaskItem: Identifiable, Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let kind: WorkbenchTaskKind
  public let title: String
  public let detail: String
  public let progress: Double?
  public let state: WorkbenchTaskState
  public let failureReason: String?
  public let canRetry: Bool
  public let targetID: UUID?

  public init(
    id: String,
    kind: WorkbenchTaskKind,
    title: String? = nil,
    detail: String,
    progress: Double? = nil,
    state: WorkbenchTaskState,
    failureReason: String? = nil,
    canRetry: Bool = false,
    targetID: UUID? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title ?? kind.title
    self.detail = detail
    self.progress = progress.map { min(1, max(0, $0)) }
    self.state = state
    self.failureReason = failureReason
    self.canRetry = canRetry
    self.targetID = targetID
  }

  public var isActive: Bool {
    state == .running
  }

  public var isFailure: Bool {
    state == .failed
  }
}
