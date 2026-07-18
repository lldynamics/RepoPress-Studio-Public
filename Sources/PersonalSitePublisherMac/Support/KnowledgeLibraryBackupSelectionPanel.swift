import AppKit
import UniformTypeIdentifiers

extension UTType {
  static let personalSiteKnowledgeLibraryBackup = UTType(
    exportedAs: "com.jinfang.personalsitepublisher.knowledge-library-backup",
    conformingTo: .package
  )
}

enum KnowledgeLibraryBackupSelectionPanel {
  @MainActor
  static func chooseBackupDestination() -> URL? {
    let panel = NSSavePanel()
    panel.title = String(localized: "备份资料库")
    panel.prompt = String(localized: "创建备份")
    panel.message = String(localized: "备份会包含资料数据库、分类、固定状态以及数据库实际引用的原文与正文。")
    panel.allowedContentTypes = [.personalSiteKnowledgeLibraryBackup]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    panel.nameFieldStringValue = "资料库备份-\(formatter.string(from: Date())).pslibrarybackup"
    return panel.runModal() == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseBackupForRestore() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择资料库备份")
    panel.prompt = String(localized: "验证备份")
    panel.message = String(localized: "应用会先校验所有文件和数据库，再显示恢复内容预览；此步骤不会修改当前资料库。")
    panel.allowedContentTypes = [.personalSiteKnowledgeLibraryBackup]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}
