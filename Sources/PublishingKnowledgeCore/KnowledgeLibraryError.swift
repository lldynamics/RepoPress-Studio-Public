import Foundation

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
  case invalidBrowserCapture(String)
  case invalidMetadata(String)
  case missingRevision
  case sourceRefreshUnavailable
  case contentRepairUnavailable(String)
  case exportFailure(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSource(let name): "暂不支持这种资料格式：\(name)"
    case .noImportableSources(let message): "拖放内容中没有可导入的资料：\(message)"
    case .unreadableSource(let path): "无法读取资料来源：\(path)"
    case .emptyContent(let name): "没有从资料中提取到可检索文本：\(name)"
    case .sourceLimitExceeded(let message): message
    case .invalidWebURL: "请输入有效的 HTTPS 网页地址。"
    case .networkFailure(let message): "网页读取失败：\(message)"
    case .database(let message): "资料库数据库错误：\(message)"
    case .databaseIntegrity(let message): "资料库数据完整性错误：\(message)"
    case .unsupportedDatabaseVersion(let found, let supported):
      "此资料库由更新版本的软件创建（数据库版本 \(found)），当前版本最高支持 \(supported)。为避免损坏，已拒绝打开。"
    case .missingDocument: "找不到这条资料。"
    case .invalidFolderName: "文件夹名称不能为空，且最多使用 80 个字符。"
    case .duplicateFolderName(let name): "已经存在名为“\(name)”的资料文件夹。"
    case .missingFolder: "找不到这个资料文件夹。"
    case .invalidBrowserCapture(let message): "浏览器页面保存失败：\(message)"
    case .invalidMetadata(let message): "资料元数据无效：\(message)"
    case .missingRevision: "找不到这条资料修订。"
    case .sourceRefreshUnavailable: "这条资料没有可重新读取的来源。"
    case .contentRepairUnavailable(let message): "无法在本机修复这条资料：\(message)"
    case .exportFailure(let message): "资料导出失败：\(message)"
    }
  }
}
