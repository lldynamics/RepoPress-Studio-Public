import AppIntents
import Foundation
import UniformTypeIdentifiers

struct QueueWebpageForRepoPressIntent: AppIntent {
  static let title: LocalizedStringResource = "保存网页到 RepoPress"
  static var openAppWhenRun: Bool { true }
  static let description = IntentDescription("将 HTTPS 网页放入 RepoPress 资料库的待导入收件箱。")

  @Parameter(
    title: "网页地址",
    inputConnectionBehavior: .connectToPreviousIntentResult
  )
  var url: URL

  static var parameterSummary: some ParameterSummary {
    Summary("将 \(\.$url) 放入 RepoPress 收件箱")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard
      url.scheme?.lowercased() == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil,
      url.absoluteString.lengthOfBytes(using: .utf8) <= 16_384
    else {
      throw ShortcutIntakeError.invalidWebURL
    }
    try await ShortcutIntakeStore.stage(.webURL(url: url, title: nil))
    return .result(dialog: "已放入 RepoPress 待导入收件箱。")
  }
}

struct QueueDocumentForRepoPressIntent: AppIntent {
  static let title: LocalizedStringResource = "保存文件到 RepoPress"
  static var openAppWhenRun: Bool { true }
  static let description = IntentDescription("将受支持的文档或图片放入 RepoPress 资料库的待导入收件箱。")

  // This macOS 14 target uses identifier filtering because the typed API starts on macOS 15.
  @Parameter(
    title: "资料文件",
    supportedTypeIdentifiers: [
      "com.adobe.pdf",
      "public.plain-text",
      "public.html",
      "net.daringfireball.markdown",
      "public.jpeg",
      "public.png",
      "public.heic",
      "org.webmproject.webp",
    ],
    inputConnectionBehavior: .connectToPreviousIntentResult
  )
  var file: IntentFile

  static var parameterSummary: some ParameterSummary {
    Summary("将 \(\.$file) 放入 RepoPress 收件箱")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let data = try ShortcutIntakeStore.validatedData(from: file)
    try await ShortcutIntakeStore.stage(
      .file(data: data, fileName: file.filename)
    )
    return .result(dialog: "已放入 RepoPress 待导入收件箱。")
  }
}

struct QueueKnowledgeNoteForRepoPressIntent: AppIntent {
  static let title: LocalizedStringResource = "保存灵感到 RepoPress"
  static var openAppWhenRun: Bool { true }
  static let description = IntentDescription("将文本作为资料库原生笔记放入 RepoPress 的待导入收件箱。")

  @Parameter(title: "标题")
  var title: String

  @Parameter(
    title: "内容",
    inputConnectionBehavior: .connectToPreviousIntentResult
  )
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("将 \(\.$title)：\(\.$text) 保存为 RepoPress 笔记")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try ShortcutIntakeStore.validateNote(text)
    try await ShortcutIntakeStore.stage(.note(text: text, title: title))
    return .result(dialog: "已放入 RepoPress 待导入收件箱。")
  }
}

struct RepoPressShortcutProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: QueueWebpageForRepoPressIntent(),
      phrases: [
        "用 \(.applicationName) 保存网页",
        "保存网页到 \(.applicationName)",
      ],
      shortTitle: "保存网页",
      systemImageName: "safari"
    )

    AppShortcut(
      intent: QueueDocumentForRepoPressIntent(),
      phrases: [
        "用 \(.applicationName) 保存资料文件",
        "保存文件到 \(.applicationName)",
      ],
      shortTitle: "保存文件",
      systemImageName: "doc.badge.plus"
    )

    AppShortcut(
      intent: QueueKnowledgeNoteForRepoPressIntent(),
      phrases: [
        "用 \(.applicationName) 保存灵感",
        "在 \(.applicationName) 中记录笔记",
      ],
      shortTitle: "保存灵感",
      systemImageName: "note.text.badge.plus"
    )
  }
}

private enum ShortcutIntakeStore {
  static let maximumFileByteCount = 50 * 1_024 * 1_024
  static let maximumImageByteCount = 25 * 1_024 * 1_024
  static let maximumTextByteCount = 1 * 1_024 * 1_024
  private static let appGroupIdentifier = "3H8UVVUCP3.com.jinfang.repopress.intake"
  private static let notificationName = Notification.Name("com.jinfang.repopress.intake.ready")
  private static let supportedFilenameExtensions: Set<String> = [
    "pdf", "md", "markdown", "mdx", "txt", "text", "html", "htm",
    "jpg", "jpeg", "png", "heic", "heif", "webp",
  ]

  static func validatedData(from file: IntentFile) throws -> Data {
    _ = try validatedFileName(file.filename)
    guard isSupported(file) else {
      throw ShortcutIntakeError.unsupportedFile
    }

    if let fileURL = file.fileURL {
      let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
      if let fileSize = values.fileSize,
        fileSize > (isImage(file) ? maximumImageByteCount : maximumFileByteCount)
      {
        throw ShortcutIntakeError.fileLimitExceeded
      }
    }

    let data = file.data
    let maximumByteCount = isImage(file) ? maximumImageByteCount : maximumFileByteCount
    guard !data.isEmpty, data.count <= maximumByteCount else {
      throw ShortcutIntakeError.fileLimitExceeded
    }
    return data
  }

  static func validateNote(_ text: String) throws {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !normalized.isEmpty,
      normalized.lengthOfBytes(using: .utf8) <= maximumTextByteCount
    else {
      throw ShortcutIntakeError.invalidNote
    }
  }

  static func stage(_ payload: ShortcutIntakePayload) async throws {
    try await Task.detached(priority: .userInitiated) {
      try stageSynchronously(payload)
    }.value
  }

  private static func stageSynchronously(_ payload: ShortcutIntakePayload) throws {
    let fileManager = FileManager.default
    guard
      let groupURL = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      throw ShortcutIntakeError.appGroupUnavailable
    }

    let inboxURL = groupURL.appendingPathComponent("Inbox", isDirectory: true)
    let identifier = UUID().uuidString
    let pendingURL = inboxURL.appendingPathComponent(".\(identifier).pending", isDirectory: true)
    let finalURL = inboxURL.appendingPathComponent(identifier, isDirectory: true)

    do {
      try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: pendingURL, withIntermediateDirectories: false)

      let manifest: ShortcutIntakeManifest
      switch payload {
      case .webURL(let url, let title):
        manifest = .init(
          kind: .webURL, url: url.absoluteString, title: title.map { String($0.prefix(200)) })
      case .note(let text, let title):
        try validateNote(text)
        manifest = .init(kind: .note, title: title.map { String($0.prefix(200)) }, text: text)
      case .file(let data, let fileName):
        let safeName = try validatedFileName(fileName)
        guard !data.isEmpty, data.count <= maximumFileByteCount else {
          throw ShortcutIntakeError.fileLimitExceeded
        }
        let storedFileName = "payload.\((safeName as NSString).pathExtension.lowercased())"
        try data.write(
          to: pendingURL.appendingPathComponent(storedFileName, isDirectory: false),
          options: .atomic
        )
        manifest = .init(
          kind: .file,
          fileName: safeName,
          storedFileName: storedFileName
        )
      }

      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(
        to: pendingURL.appendingPathComponent("manifest.json", isDirectory: false),
        options: .atomic
      )

      try fileManager.moveItem(at: pendingURL, to: finalURL)
      DistributedNotificationCenter.default().postNotificationName(
        notificationName,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
      )
    } catch {
      try? fileManager.removeItem(at: pendingURL)
      throw error
    }
  }

  private static func isSupported(_ file: IntentFile) -> Bool {
    let fileName = file.filename as NSString
    guard supportedFilenameExtensions.contains(fileName.pathExtension.lowercased()) else {
      return false
    }
    guard let type = file.type else { return true }
    return type.conforms(to: .pdf)
      || type.conforms(to: .plainText)
      || type.conforms(to: .html)
      || type.identifier == "net.daringfireball.markdown"
      || type.conforms(to: .jpeg)
      || type.conforms(to: .png)
      || type.conforms(to: .heic)
      || type.conforms(to: .webP)
  }

  private static func isImage(_ file: IntentFile) -> Bool {
    if let type = file.type, type.conforms(to: .image) { return true }
    return ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(
      (file.filename as NSString).pathExtension.lowercased()
    )
  }

  private static func validatedFileName(_ fileName: String) throws -> String {
    let safeName = (fileName as NSString).lastPathComponent
    let extensionName = (safeName as NSString).pathExtension.lowercased()
    guard
      !safeName.isEmpty,
      safeName != ".",
      safeName != "..",
      supportedFilenameExtensions.contains(extensionName)
    else {
      throw ShortcutIntakeError.unsupportedFile
    }
    return safeName
  }
}

private enum ShortcutIntakePayload: Sendable {
  case webURL(url: URL, title: String?)
  case file(data: Data, fileName: String)
  case note(text: String, title: String?)
}

private struct ShortcutIntakeManifest: Encodable {
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

private enum ShortcutIntakeError: LocalizedError {
  case appGroupUnavailable
  case fileLimitExceeded
  case invalidNote
  case invalidWebURL
  case unsupportedFile

  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable:
      return "无法访问 RepoPress 共享收件箱。"
    case .fileLimitExceeded:
      return "文件为空或超过 50 MB；图片不得超过 25 MB，未加入收件箱。"
    case .invalidNote:
      return "备忘不能为空，且正文不能超过 1 MB。"
    case .invalidWebURL:
      return "只支持无账号信息且不超过 16 KB 的 HTTPS 网页地址。"
    case .unsupportedFile:
      return "仅支持 PDF、Markdown、文本、HTML 和常见图片文件。"
    }
  }
}
