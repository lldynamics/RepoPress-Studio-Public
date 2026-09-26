import AppKit
import Foundation
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
  private let titleLabel = NSTextField(labelWithString: "正在保存到 RepoPress…")
  private let detailLabel = NSTextField(wrappingLabelWithString: "请保持此窗口打开，直到保存完成。")
  private let progressIndicator = NSProgressIndicator()
  private let doneButton = NSButton(title: "完成", target: nil, action: nil)
  private var hasCompletedRequest = false
  private var savedCount = 0

  override func loadView() {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.maximumNumberOfLines = 0
    progressIndicator.style = .spinning
    progressIndicator.controlSize = .regular
    progressIndicator.startAnimation(nil)

    doneButton.target = self
    doneButton.action = #selector(finish)
    doneButton.isHidden = true

    let stack = NSStackView(views: [titleLabel, detailLabel, progressIndicator, doneButton])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
      view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
    ])

    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    Task { [weak self] in
      await self?.stageSharedItems()
    }
  }

  @MainActor
  private func stageSharedItems() async {
    let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = extensionItems.flatMap { $0.attachments ?? [] }

    guard !providers.isEmpty else {
      showFailure("没有收到可保存的内容。")
      return
    }

    do {
      for (index, provider) in providers.enumerated() {
        updateProgress("正在保存第 \(index + 1) 项，共 \(providers.count) 项…")
        let intake = try await IntakeLoader.load(from: provider)
        try await IntakeStagingStore.stage(intake)
        savedCount += 1
      }
      showSuccess(savedCount)
    } catch {
      showFailure(error.localizedDescription)
    }
  }

  @MainActor
  private func updateProgress(_ detail: String) {
    detailLabel.stringValue = detail
  }

  @MainActor
  private func showSuccess(_ count: Int) {
    titleLabel.stringValue = "已交给 RepoPress，等待导入"
    detailLabel.stringValue =
      count == 1
      ? "资料已放入待导入收件箱。打开 RepoPress 后会完成导入。"
      : "\(count) 项资料已放入待导入收件箱。打开 RepoPress 后会完成导入。"
    progressIndicator.stopAnimation(nil)
    progressIndicator.isHidden = true

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.finish()
    }
  }

  @MainActor
  private func showFailure(_ message: String) {
    titleLabel.stringValue = savedCount > 0 ? "部分资料已加入收件箱" : "无法保存到 RepoPress"
    detailLabel.stringValue =
      savedCount > 0
      ? "已暂存 \(savedCount) 项；其余内容未暂存：\(message)"
      : message
    progressIndicator.stopAnimation(nil)
    progressIndicator.isHidden = true
    doneButton.isHidden = false
  }

  @objc
  private func finish() {
    guard !hasCompletedRequest else { return }
    hasCompletedRequest = true
    extensionContext?.completeRequest(returningItems: nil)
  }
}

@MainActor
private enum IntakeLoader {
  static func load(from provider: NSItemProvider) async throws -> IntakePayload {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      let url = try await loadOwnedFileURL(
        from: provider, typeIdentifier: UTType.fileURL.identifier)
      return try filePayload(from: url, suggestedName: provider.suggestedName, contentType: nil)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      let url = try await loadURL(from: provider, typeIdentifier: UTType.url.identifier)
      guard url.scheme?.lowercased() == "https",
        url.host != nil,
        url.user == nil,
        url.password == nil,
        url.absoluteString.lengthOfBytes(using: .utf8) <= 16_384
      else {
        throw IntakeError.unsupportedURL
      }
      return .webURL(url: url, title: provider.suggestedName)
    }

    if let contentType = supportedFileContentType(in: provider) {
      let url = try await loadOwnedFileRepresentation(
        from: provider, typeIdentifier: contentType.identifier)
      return try filePayload(
        from: url, suggestedName: provider.suggestedName, contentType: contentType)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      let text = try await loadText(from: provider)
      let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedText.isEmpty else { throw IntakeError.emptyText }
      guard text.lengthOfBytes(using: .utf8) <= IntakeStagingStore.maximumNoteBytes else {
        throw IntakeError.noteTooLarge
      }
      if let url = URL(string: trimmedText),
        url.scheme?.lowercased() == "https",
        url.host != nil,
        url.user == nil,
        url.password == nil,
        url.absoluteString.lengthOfBytes(using: .utf8) <= 16_384
      {
        return .webURL(url: url, title: provider.suggestedName)
      }
      return .note(text: text, title: provider.suggestedName)
    }

    throw IntakeError.unsupportedItem
  }

  private static func supportedFileContentType(in provider: NSItemProvider) -> UTType? {
    provider.registeredTypeIdentifiers
      .compactMap { UTType($0) }
      .first(where: { type in
        type.conforms(to: .pdf)
          || type.conforms(to: .image)
          || type.conforms(to: .html)
          || type.identifier == "net.daringfireball.markdown"
      })
  }

  private static func loadURL(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        if let url = item as? URL {
          continuation.resume(returning: url)
          return
        }
        if let url = item as? NSURL {
          continuation.resume(returning: url as URL)
          return
        }
        if let rawURL = item as? String,
          let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          continuation.resume(returning: url)
          return
        }
        continuation.resume(throwing: IntakeError.unreadableItem)
      }
    }
  }

  private static func loadText(from provider: NSItemProvider) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
        item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        if let text = item as? String {
          continuation.resume(returning: text)
          return
        }
        if let text = item as? NSString {
          continuation.resume(returning: text as String)
          return
        }
        continuation.resume(throwing: IntakeError.unreadableItem)
      }
    }
  }

  private static func loadOwnedFileURL(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let sourceURL = (item as? URL) ?? (item as? NSURL).map { $0 as URL }
        guard let sourceURL else {
          continuation.resume(throwing: IntakeError.unreadableItem)
          return
        }
        do {
          continuation.resume(returning: try makeOwnedTemporaryCopy(of: sourceURL))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func loadOwnedFileRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let url else {
          continuation.resume(throwing: IntakeError.unreadableItem)
          return
        }
        do {
          continuation.resume(returning: try makeOwnedTemporaryCopy(of: url))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  nonisolated private static func makeOwnedTemporaryCopy(of sourceURL: URL) throws -> URL {
    let fileManager = FileManager.default
    let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if needsSecurityScope {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let values = try sourceURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw IntakeError.unsupportedItem
    }
    guard (values.fileSize ?? 0) <= IntakeStagingStore.maximumFileBytes else {
      throw IntakeError.fileTooLarge
    }
    let temporaryName = "RepoPressShare-\(UUID().uuidString)"
    var destinationURL = fileManager.temporaryDirectory.appendingPathComponent(temporaryName)
    if !sourceURL.pathExtension.isEmpty {
      destinationURL.appendPathExtension(sourceURL.pathExtension)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private static func filePayload(
    from url: URL,
    suggestedName: String?,
    contentType: UTType?
  ) throws -> IntakePayload {
    let needsSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if needsSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let values = try url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw IntakeError.unsupportedItem
    }
    let resolvedContentType = contentType ?? values.contentType
    guard isSupportedFile(url: url, contentType: resolvedContentType) else {
      throw IntakeError.unsupportedFile
    }
    guard (values.fileSize ?? 0) <= IntakeStagingStore.maximumFileBytes else {
      throw IntakeError.fileTooLarge
    }
    if resolvedContentType?.conforms(to: .image) == true,
      (values.fileSize ?? 0) > IntakeStagingStore.maximumImageBytes
    {
      throw IntakeError.imageTooLarge
    }

    guard let fileExtension = normalizedExtension(for: url, contentType: resolvedContentType) else {
      throw IntakeError.unsupportedFile
    }
    let displayName = sanitizedDisplayName(
      suggestedName ?? url.lastPathComponent, fileExtension: fileExtension)
    return .file(
      sourceURL: url,
      originalFileName: displayName,
      storedFileName: "payload.\(fileExtension)"
    )
  }

  private static func isSupportedFile(url: URL, contentType: UTType?) -> Bool {
    guard let fileExtension = normalizedExtension(for: url, contentType: contentType) else {
      return false
    }
    let supportedDocumentExtensions: Set<String> = [
      "pdf", "md", "markdown", "mdx", "txt", "text", "html", "htm",
    ]
    if supportedDocumentExtensions.contains(fileExtension) { return true }

    let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
    return contentType?.conforms(to: .image) == true
      && supportedImageExtensions.contains(fileExtension)
  }

  private static func normalizedExtension(for url: URL, contentType: UTType?) -> String? {
    let pathExtension = url.pathExtension.lowercased()
    if !pathExtension.isEmpty { return pathExtension }
    if let preferredExtension = contentType?.preferredFilenameExtension, !preferredExtension.isEmpty
    {
      return preferredExtension.lowercased()
    }
    return nil
  }

  private static func sanitizedDisplayName(_ name: String, fileExtension: String) -> String {
    let lastPathComponent = (name as NSString).lastPathComponent
    let withoutControls = lastPathComponent.components(separatedBy: .controlCharacters).joined()
    let trimmed = withoutControls.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if trimmed.isEmpty { return "Untitled.\(fileExtension)" }
    let currentExtension = (trimmed as NSString).pathExtension.lowercased()
    if currentExtension == fileExtension { return trimmed }
    let knownExtensions: Set<String> = [
      "pdf", "md", "markdown", "mdx", "txt", "text", "html", "htm",
      "jpg", "jpeg", "png", "heic", "heif", "webp",
    ]
    let stem =
      knownExtensions.contains(currentExtension)
      ? (trimmed as NSString).deletingPathExtension
      : trimmed
    return "\(stem).\(fileExtension)"
  }
}

private enum IntakeStagingStore {
  static let maximumFileBytes = 50 * 1024 * 1024
  static let maximumImageBytes = 25 * 1024 * 1024
  static let maximumNoteBytes = 1 * 1024 * 1024
  private static let appGroupIdentifier = "3H8UVVUCP3.com.jinfang.repopress.intake"

  static func stage(_ payload: IntakePayload) async throws {
    defer {
      if case .file(let sourceURL, _, _) = payload {
        try? FileManager.default.removeItem(at: sourceURL)
      }
    }
    try await Task.detached(priority: .userInitiated) {
      try stageSynchronously(payload)
    }.value
  }

  private static func stageSynchronously(_ payload: IntakePayload) throws {
    let fileManager = FileManager.default
    guard
      let groupURL = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      throw IntakeError.appGroupUnavailable
    }

    let inboxURL = groupURL.appendingPathComponent("Inbox", isDirectory: true)
    let identifier = UUID().uuidString
    let pendingURL = inboxURL.appendingPathComponent(".\(identifier).pending", isDirectory: true)
    let finalURL = inboxURL.appendingPathComponent(identifier, isDirectory: true)

    do {
      try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: pendingURL, withIntermediateDirectories: false)

      let manifest: IntakeManifest
      switch payload {
      case .webURL(let url, let title):
        manifest = IntakeManifest(
          kind: .webURL, url: url.absoluteString, title: title.map { String($0.prefix(200)) })
      case .note(let text, let title):
        manifest = IntakeManifest(
          kind: .note, title: title.map { String($0.prefix(200)) }, text: text)
      case .file(let sourceURL, let originalFileName, let storedFileName):
        let destinationURL = pendingURL.appendingPathComponent(storedFileName)
        let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
          if needsSecurityScope {
            sourceURL.stopAccessingSecurityScopedResource()
          }
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        manifest = IntakeManifest(
          kind: .file,
          fileName: originalFileName,
          storedFileName: storedFileName
        )
      }

      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(
        to: pendingURL.appendingPathComponent("manifest.json"),
        options: .atomic
      )

      try fileManager.moveItem(at: pendingURL, to: finalURL)
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.jinfang.repopress.intake.ready"),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
      )
    } catch {
      try? fileManager.removeItem(at: pendingURL)
      throw error
    }
  }
}

private enum IntakePayload: Sendable {
  case webURL(url: URL, title: String?)
  case file(sourceURL: URL, originalFileName: String, storedFileName: String)
  case note(text: String, title: String?)
}

private struct IntakeManifest: Encodable {
  enum Kind: String, Encodable {
    case webURL
    case file
    case note
  }

  let version = 1
  let kind: Kind
  let url: String?
  let title: String?
  let text: String?
  let fileName: String?
  let storedFileName: String?
  let createdAt: Date

  init(
    kind: Kind,
    url: String? = nil,
    title: String? = nil,
    text: String? = nil,
    fileName: String? = nil,
    storedFileName: String? = nil,
    createdAt: Date = Date()
  ) {
    self.kind = kind
    self.url = url
    self.title = title
    self.text = text
    self.fileName = fileName
    self.storedFileName = storedFileName
    self.createdAt = createdAt
  }
}

private enum IntakeError: LocalizedError {
  case appGroupUnavailable
  case emptyText
  case fileTooLarge
  case imageTooLarge
  case noteTooLarge
  case unreadableItem
  case unsupportedFile
  case unsupportedItem
  case unsupportedURL

  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable:
      return "无法访问 RepoPress 共享收件箱。请确认扩展已启用 App Group。"
    case .emptyText:
      return "不能保存空白文本。"
    case .fileTooLarge:
      return "文件超过 50 MB，未保存。"
    case .imageTooLarge:
      return "图片超过 25 MB，未保存。"
    case .noteTooLarge:
      return "文本超过 1 MiB，未保存。"
    case .unreadableItem:
      return "无法读取共享内容。"
    case .unsupportedFile:
      return "仅支持 PDF、Markdown、文本、HTML 和图片文件。"
    case .unsupportedItem:
      return "此内容类型无法保存。"
    case .unsupportedURL:
      return "仅支持无账号信息且不超过 16 KB 的 HTTPS 网页链接。"
    }
  }
}
