import AppKit

@MainActor
enum WorkbenchDataRootSelectionPanel {
  static func chooseExistingDataRoot() async -> URL? {
    await chooseDirectory(
      title: String(localized: "恢复已有数据文件夹"),
      message: String(localized: "请选择包含 repopress-data-root.json 的数据文件夹。"),
      prompt: String(localized: "恢复此文件夹"),
      canCreateDirectories: false
    )
  }

  static func chooseDestinationParent(forMigration: Bool) async -> URL? {
    await chooseDirectory(
      title: forMigration
        ? String(localized: "选择迁移目的地")
        : String(localized: "选择数据保存位置"),
      message: String(localized: "RepoPress Studio 会在所选位置中新建一个“RepoPress Data”文件夹。"),
      prompt: String(localized: "选择此位置"),
      canCreateDirectories: true
    )
  }

  private static func chooseDirectory(
    title: String,
    message: String,
    prompt: String,
    canCreateDirectories: Bool
  ) async -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.prompt = prompt
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = canCreateDirectories
    panel.resolvesAliases = true
    panel.directoryURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first

    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
