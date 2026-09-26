import AppKit
import UniformTypeIdentifiers

extension UTType {
  static let personalSiteWorkspaceBackup = UTType(
    exportedAs: "com.jinfang.personalsitepublisher.workspace-backup",
    conformingTo: .package
  )
}

enum WorkspaceBackupSelectionPanel {
  @MainActor
  static func chooseBackupDestination() async -> URL? {
    await chooseBackupDestination(
      title: String(localized: "备份完整工作区"),
      message: String(localized: "包含草稿、历史版本、站点配置、资料库、RSS、附件和发布记录；不包含 API Key。可在系统面板中选择保存位置。"),
      filename: String(localized: "工作区备份")
    )
  }

  @MainActor
  static func chooseSelectiveBackupDestination() async -> URL? {
    await chooseBackupDestination(
      title: String(localized: "备份所选类别"),
      message: String(localized: "仅保存所选的数据类别；API Key 和 AI 服务凭据不会写入。可在系统面板中选择保存位置。"),
      filename: String(localized: "所选工作区备份")
    )
  }

  @MainActor
  private static func chooseBackupDestination(title: String, message: String, filename: String)
    async -> URL?
  {
    let panel = NSSavePanel()
    panel.title = title
    panel.prompt = String(localized: "创建备份")
    panel.message = message
    panel.allowedContentTypes = [.personalSiteWorkspaceBackup]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    panel.nameFieldStringValue = String(
      format: String(localized: "%@-%@.psworkspacebackup"),
      filename,
      formatter.string(from: Date())
    )
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseBackupForRestore() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择工作区备份")
    panel.prompt = String(localized: "验证备份")
    panel.message = String(
      localized: "可从 Google Drive for desktop 等文件位置选择备份包。应用会先校验清单、快照、资料库、RSS 和附件；此步骤不会修改当前工作区。"
    )
    panel.allowedContentTypes = [.personalSiteWorkspaceBackup]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseBackupDirectory() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择自动备份目录")
    panel.prompt = String(localized: "使用此目录")
    panel.message = String(
      localized: "应用会在此目录创建每日或每周工作区备份，并在创建后自动校验。云盘同步状态由文件提供器管理；应用只报告本地创建与校验结果。"
    )
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }
}
