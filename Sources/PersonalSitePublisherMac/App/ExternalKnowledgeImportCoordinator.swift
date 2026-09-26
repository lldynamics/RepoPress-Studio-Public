import AppKit
import Combine
import Foundation
import PublishingKnowledgeCore
import PublishingWorkbenchCore

/// Receives user-initiated content from Shortcuts and the macOS Share extension.
/// The extension only stages bytes; the configured workbench owns every library write.
@MainActor
final class ExternalKnowledgeImportCoordinator: NSObject, ObservableObject {
  static let shared = ExternalKnowledgeImportCoordinator()

  static let appGroupIdentifier = "3H8UVVUCP3.com.jinfang.repopress.intake"
  static let notificationName = Notification.Name("com.jinfang.repopress.intake.ready")
  static let maximumFileByteCount = 50 * 1_024 * 1_024
  static let maximumTextByteCount = 1 * 1_024 * 1_024
  static let maximumURLByteCount = 16_384

  @Published private(set) var inboxError: String?
  private weak var workbenchStore: WorkbenchStore?
  private var drainTask: Task<Void, Never>?
  private var needsAnotherDrain = false

  private override init() {
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(inboxDidChange(_:)),
      name: Self.notificationName,
      object: nil
    )
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
  }

  func install(store: WorkbenchStore) {
    workbenchStore = store
    scheduleInboxDrain()
  }

  func scheduleInboxDrain() {
    guard workbenchStore != nil else { return }
    guard drainTask == nil else {
      needsAnotherDrain = true
      return
    }
    drainTask = Task { @MainActor in
      await drainInbox()
      drainTask = nil
      if needsAnotherDrain {
        needsAnotherDrain = false
        scheduleInboxDrain()
      }
    }
  }

  @objc private func inboxDidChange(_ notification: Notification) {
    scheduleInboxDrain()
  }

  @discardableResult
  func importWebURL(_ url: URL) async throws -> String {
    guard url.scheme?.lowercased() == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil,
      url.absoluteString.lengthOfBytes(using: .utf8) <= Self.maximumURLByteCount
    else {
      throw ExternalKnowledgeImportError.invalidWebURL
    }
    let store = try readyStore()
    let preview = try await store.knowledge.makeWebImportPreview(url: url)
    let result = try await store.knowledge.commit(preview)
    store.selectSection(.library)
    return resultSummary(result)
  }

  @discardableResult
  func importFile(data: Data, fileName: String) async throws -> String {
    guard !data.isEmpty, data.count <= Self.maximumFileByteCount else {
      throw ExternalKnowledgeImportError.fileLimitExceeded
    }
    let safeName = try validatedFileName(fileName)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPressIntake-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(safeName, isDirectory: false)
    try data.write(to: fileURL, options: .atomic)
    return try await importFile(at: fileURL)
  }

  @discardableResult
  func importNote(title: String, text: String) async throws -> String {
    try await importNote(title: title, text: text, id: UUID())
  }

  private func importNote(title: String, text: String, id: UUID) async throws -> String {
    let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty,
      normalizedText.lengthOfBytes(using: .utf8) <= Self.maximumTextByteCount
    else {
      throw ExternalKnowledgeImportError.invalidNote
    }
    let store = try readyStore()
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitle =
      normalizedTitle.isEmpty
      ? (normalizedText.components(separatedBy: .newlines).first ?? "灵感备忘")
      : normalizedTitle
    let note = KnowledgeNote(
      id: id,
      title: String(displayTitle.prefix(200)),
      markdown: normalizedText
    )
    guard await store.knowledge.createNote(note) != nil else {
      throw ExternalKnowledgeImportError.libraryWriteFailed(
        store.knowledge.lastError ?? "笔记无法保存到资料库。"
      )
    }
    store.selectSection(.library)
    return "已保存到 RepoPress 资料库。"
  }

  private func importFile(at fileURL: URL, displayName: String? = nil) async throws -> String {
    if let displayName {
      let safeName = try validatedFileName(displayName)
      guard safeName == displayName,
        (safeName as NSString).pathExtension.lowercased()
          == (fileURL.lastPathComponent as NSString).pathExtension.lowercased()
      else { throw ExternalKnowledgeImportError.invalidInboxItem }
      if safeName != fileURL.lastPathComponent {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("RepoPressIntake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let namedURL = directory.appendingPathComponent(safeName, isDirectory: false)
        try FileManager.default.copyItem(at: fileURL, to: namedURL)
        return try await importFile(at: namedURL)
      }
    }
    let store = try readyStore()
    _ = try validatedFileName(fileURL.lastPathComponent)
    let preview = try await store.knowledge.makeImportPreview(sourceURL: fileURL)
    let result = try await store.knowledge.commit(preview)
    store.selectSection(.library)
    return resultSummary(result)
  }

  private func readyStore() throws -> WorkbenchStore {
    guard let workbenchStore else {
      throw ExternalKnowledgeImportError.dataRootUnavailable
    }
    return workbenchStore
  }

  private func resultSummary(_ result: KnowledgeImportResult) -> String {
    "资料库已保存：新增 \(result.insertedCount)，更新 \(result.updatedCount)，跳过 \(result.skippedCount)。"
  }

  private func validatedFileName(_ fileName: String) throws -> String {
    let name = (fileName as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    let supported = Set([
      "pdf", "md", "markdown", "mdx", "txt", "text", "html", "htm",
      "jpg", "jpeg", "png", "heic", "heif", "webp",
    ])
    guard !name.isEmpty, name != ".", name != "..", supported.contains(ext) else {
      throw ExternalKnowledgeImportError.unsupportedFile
    }
    return name
  }

  private func drainInbox() async {
    let fileManager = FileManager.default
    guard
      let container = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
      )
    else {
      inboxError = "系统共享暂存区不可用。请检查 RepoPress 的 App Group 签名。"
      return
    }
    let inboxURL = container.appendingPathComponent("Inbox", isDirectory: true)
    let entryURLs: [URL]
    do {
      entryURLs = try fileManager.contentsOfDirectory(
        at: inboxURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      inboxError = nil
      return
    } catch {
      inboxError = "无法读取系统共享暂存区：\(error.localizedDescription)"
      return
    }
    guard !entryURLs.isEmpty else {
      inboxError = nil
      return
    }
    var firstFailure: String?
    for entryURL in entryURLs {
      do {
        try await importInboxEntry(at: entryURL)
        try fileManager.removeItem(at: entryURL)
      } catch {
        // Keep the staged bytes for a later retry; never acknowledge a failed
        // library write by silently deleting the only copy.
        if firstFailure == nil {
          firstFailure = "系统共享资料待导入：\(error.localizedDescription)"
        }
      }
    }
    inboxError = firstFailure
  }

  private func importInboxEntry(at entryURL: URL) async throws {
    let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      let noteID = UUID(uuidString: entryURL.lastPathComponent)
    else {
      throw ExternalKnowledgeImportError.invalidInboxItem
    }
    let manifestURL = entryURL.appendingPathComponent("manifest.json", isDirectory: false)
    let manifestValues = try manifestURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
      (manifestValues.fileSize ?? 0) <= Self.maximumTextByteCount * 6 + 16_384
    else {
      throw ExternalKnowledgeImportError.invalidInboxItem
    }
    let manifest = try JSONDecoder().decode(
      InboxManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    guard manifest.version == 1 else {
      throw ExternalKnowledgeImportError.invalidInboxItem
    }
    switch manifest.kind {
    case .webURL:
      guard let rawURL = manifest.url,
        let url = URL(string: rawURL)
      else { throw ExternalKnowledgeImportError.invalidWebURL }
      try await importWebURL(url)
    case .note:
      guard let text = manifest.text else {
        throw ExternalKnowledgeImportError.invalidNote
      }
      let store = try readyStore()
      if let existing = await store.knowledge.note(documentID: noteID) {
        guard existing.markdown == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
          throw ExternalKnowledgeImportError.invalidInboxItem
        }
        return
      }
      _ = try await importNote(title: manifest.title ?? "", text: text, id: noteID)
    case .file:
      guard let storedFileName = manifest.storedFileName ?? manifest.fileName else {
        throw ExternalKnowledgeImportError.invalidInboxItem
      }
      let safeName = try validatedFileName(storedFileName)
      guard safeName == storedFileName else {
        throw ExternalKnowledgeImportError.invalidInboxItem
      }
      let fileURL = entryURL.appendingPathComponent(safeName, isDirectory: false)
      let fileValues = try fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
        let byteCount = fileValues.fileSize,
        byteCount > 0,
        byteCount <= Self.maximumFileByteCount
      else { throw ExternalKnowledgeImportError.fileLimitExceeded }
      _ = try await importFile(at: fileURL, displayName: manifest.fileName)
    }
  }
}

private struct InboxManifest: Decodable {
  enum Kind: String, Decodable {
    case webURL
    case file
    case note
  }

  let version: Int
  let kind: Kind
  let url: String?
  let title: String?
  let text: String?
  let fileName: String?
  let storedFileName: String?
}

private enum ExternalKnowledgeImportError: LocalizedError {
  case dataRootUnavailable
  case invalidWebURL
  case invalidNote
  case unsupportedFile
  case fileLimitExceeded
  case invalidInboxItem
  case libraryWriteFailed(String)

  var errorDescription: String? {
    switch self {
    case .dataRootUnavailable: "请先打开 RepoPress 并设置数据文件夹。"
    case .invalidWebURL: "只支持无账号信息且不超过 16 KB 的 HTTPS 网页地址。"
    case .invalidNote: "备忘不能为空，且正文不能超过 1 MB。"
    case .unsupportedFile: "此文件类型不受资料库支持。"
    case .fileLimitExceeded: "文件为空或超过 50 MB。"
    case .invalidInboxItem: "系统共享暂存内容不完整或不受支持。"
    case .libraryWriteFailed(let detail): detail
    }
  }
}
