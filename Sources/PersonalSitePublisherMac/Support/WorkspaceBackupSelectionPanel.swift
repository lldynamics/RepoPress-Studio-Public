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
  static func chooseBackupDestination() -> URL? {
    let panel = NSSavePanel()
    panel.title = String(localized: "备份完整工作区")
    panel.prompt = String(localized: "创建备份")
    panel.message = String(
      localized: "包含草稿、历史版本、站点配置、资料库、RSS、附件和发布记录；默认不包含 API Key。"
    )
    panel.allowedContentTypes = [.personalSiteWorkspaceBackup]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    panel.nameFieldStringValue = String(
      format: String(localized: "工作区备份-%@.psworkspacebackup"),
      formatter.string(from: Date())
    )
    return panel.runModal() == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseBackupForRestore() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择工作区备份")
    panel.prompt = String(localized: "验证备份")
    panel.message = String(
      localized: "应用会先校验清单、快照、资料库、RSS 和附件；此步骤不会修改当前工作区。"
    )
    panel.allowedContentTypes = [.personalSiteWorkspaceBackup]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseBackupDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择自动备份目录")
    panel.prompt = String(localized: "使用此目录")
    panel.message = String(
      localized: "应用会在此目录创建每日或每周工作区备份，并在创建后自动校验。"
    )
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
  }
}
