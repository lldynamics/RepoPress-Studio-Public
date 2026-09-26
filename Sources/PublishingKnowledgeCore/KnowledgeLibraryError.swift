import Foundation
import PublishingCoreSupport

public enum KnowledgeLibraryError: LocalizedError, Sendable {
  case unsupportedSource(String)
  case noImportableSources(String)
  case unreadableSource(String)
  case emptyContent(String)
  case sourceLimitExceeded(String)
  case invalidWebURL
  case networkFailure(String)
  case database(String)
  case databaseIntegrity(String)
  case unsupportedDatabaseVersion(found: Int, supported: Int)
  case missingDocument
  case invalidFolderName
  case duplicateFolderName(String)
  case missingFolder
  case invalidMetadata(String)
  case invalidNoteSourceURL
  case staleNoteRevision
  case missingRevision
  case sourceRefreshUnavailable
  case contentRepairUnavailable(String)
  case exportFailure(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSource(let name): CoreL10n.format("暂不支持这种资料格式：%@", name)
    case .noImportableSources(let message): CoreL10n.format("拖放内容中没有可导入的资料：%@", message)
    case .unreadableSource(let path): CoreL10n.format("无法读取资料来源：%@", path)
    case .emptyContent(let name): CoreL10n.format("没有从资料中提取到可检索文本：%@", name)
    case .sourceLimitExceeded(let message): CoreL10n.text(message)
    case .invalidWebURL: CoreL10n.text("请输入有效的 HTTPS 网页地址。")
    case .networkFailure(let message): CoreL10n.format("网页读取失败：%@", message)
    case .database(let message): CoreL10n.format("资料库数据库错误：%@", message)
    case .databaseIntegrity(let message): CoreL10n.format("资料库数据完整性错误：%@", message)
    case .unsupportedDatabaseVersion(let found, let supported):
      CoreL10n.format("此资料库由更新版本的软件创建（数据库版本 %d），当前版本最高支持 %d。为避免损坏，已拒绝打开。", found, supported)
    case .missingDocument: CoreL10n.text("找不到这条资料。")
    case .invalidFolderName: CoreL10n.text("文件夹名称不能为空，且最多使用 80 个字符。")
    case .duplicateFolderName(let name): CoreL10n.format("已经存在名为“%@”的资料文件夹。", name)
    case .missingFolder: CoreL10n.text("找不到这个资料文件夹。")
    case .invalidMetadata(let message): CoreL10n.format("资料元数据无效：%@", message)
    case .invalidNoteSourceURL:
      CoreL10n.text("笔记来源必须是包含站点域名的 HTTP(S) 地址，且不能包含用户名或密码。")
    case .staleNoteRevision:
      CoreL10n.text("笔记在你编辑时已在其他设备更新。没有覆盖新内容；请重新打开笔记，或保存为冲突副本。")
    case .missingRevision: CoreL10n.text("找不到这条资料修订。")
    case .sourceRefreshUnavailable: CoreL10n.text("这条资料没有可重新读取的来源。")
    case .contentRepairUnavailable(let message): CoreL10n.format("无法在本机修复这条资料：%@", message)
    case .exportFailure(let message): CoreL10n.format("资料导出失败：%@", message)
    }
  }
}
