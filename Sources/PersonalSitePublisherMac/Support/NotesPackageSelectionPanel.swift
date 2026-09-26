import AppKit
import UniformTypeIdentifiers

extension UTType {
  static let repoPressNotesPackage = UTType(
    exportedAs: "com.repopress.notes-package",
    conformingTo: .package
  )
}

enum NotesPackageSelectionPanel {
  @MainActor
  static func chooseExportDestination() async -> URL? {
    let panel = NSSavePanel()
    panel.title = String(localized: "导出笔记")
    panel.prompt = String(localized: "导出")
    panel.message = String(localized: "只导出本次选中的笔记和附件；笔记包可由另一台设备导入。")
    panel.allowedContentTypes = [.repoPressNotesPackage]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    panel.nameFieldStringValue = "RepoPress-笔记-\(formatter.string(from: Date())).rpnotes"
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseImportPackage() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "导入笔记")
    panel.prompt = String(localized: "验证并预览")
    panel.message = String(localized: "可从 Google Drive for desktop 等文件位置选择笔记包。导入前先校验；相同 ID 的不同内容不会自动覆盖本机笔记。")
    panel.allowedContentTypes = [.repoPressNotesPackage]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseSnapshotPackage() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择要恢复的笔记快照")
    panel.prompt = String(localized: "预览恢复")
    panel.message = String(localized: "可从 Google Drive for desktop 等文件位置选择笔记快照。恢复前会预览新增、相同和冲突笔记；本机原笔记不会被覆盖。")
    panel.allowedContentTypes = [.repoPressNotesPackage]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseSnapshotDirectory() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择笔记快照文件夹")
    panel.prompt = String(localized: "选择文件夹")
    panel.message = String(localized: "可选择保存文件夹。每次备份都会新增一份带时间戳的笔记快照。")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }
}
