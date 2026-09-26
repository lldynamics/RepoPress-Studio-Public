import AppKit
import Foundation
import UniformTypeIdentifiers

private enum WorkspaceExchangeFilePanelError: LocalizedError {
  case invalidPackageFile

  var errorDescription: String? {
    String(localized: "交换文件无效或超过 80 MiB 上限。")
  }
}

extension UTType {
  static let repoPressWorkspaceExchange = UTType(
    exportedAs: "com.repopress.workspace-exchange",
    conformingTo: .json
  )
}

enum WorkspaceExchangeFilePanel {
  private static let maximumPackageByteCount = 80 * 1_024 * 1_024
  private static let fileExtension = "rpworkspaceexchange"

  @MainActor
  static func chooseExportDestination() async -> URL? {
    let panel = NSSavePanel()
    panel.title = String(localized: "导出跨端交换文件")
    panel.prompt = String(localized: "导出")
    panel.message = String(
      localized: "保存单文件 .rpworkspaceexchange 到所选位置。"
    )
    panel.allowedContentTypes = [.repoPressWorkspaceExchange]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = "RepoPress-Workspace-\(Self.timestamp()).rpworkspaceexchange"
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseImportSource() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择跨端交换文件")
    panel.prompt = String(localized: "验证并预览")
    panel.message = String(
      localized: "可从 Google Drive 等系统文件位置选择单文件交换包。应用会先校验完整包，不会覆盖现有草稿。"
    )
    panel.allowedContentTypes = [.repoPressWorkspaceExchange]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return await WindowSheetPresenter.response(to: panel) == .OK ? panel.url : nil
  }

  static func readPackageData(from url: URL, fileManager: FileManager = .default) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      size >= 0,
      size <= maximumPackageByteCount
    else { throw WorkspaceExchangeFilePanelError.invalidPackageFile }

    var coordinationError: NSError?
    var readError: Error?
    var result: Data?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedURL in
      do {
        let data = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
        guard data.count == size else { throw WorkspaceExchangeFilePanelError.invalidPackageFile }
        result = data
      } catch { readError = error }
    }
    if let coordinationError { throw coordinationError }
    if let readError { throw readError }
    guard let result else { throw WorkspaceExchangeFilePanelError.invalidPackageFile }
    return result
  }

  static func writePackageData(
    _ data: Data,
    to url: URL,
    fileManager: FileManager = .default
  ) throws {
    guard data.count <= maximumPackageByteCount,
      url.pathExtension.lowercased() == fileExtension
    else { throw WorkspaceExchangeFilePanelError.invalidPackageFile }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedURL in
      do { try data.write(to: coordinatedURL, options: .atomic) }
      catch { writeError = error }
    }
    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}
