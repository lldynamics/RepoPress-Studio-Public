import Foundation

public struct LocalSitePreviewPlan: Codable, Hashable, Sendable {
  public var siteKind: SiteKind
  public var rootPath: String
  public var executablePath: String
  public var arguments: [String]
  public var command: String
  public var previewURL: URL
  public var notes: [String]

  public init(
    siteKind: SiteKind,
    rootPath: String,
    executablePath: String,
    arguments: [String],
    command: String,
    previewURL: URL,
    notes: [String]
  ) {
    self.siteKind = siteKind
    self.rootPath = rootPath
    self.executablePath = executablePath
    self.arguments = arguments
    self.command = command
    self.previewURL = previewURL
    self.notes = notes
  }
}

public struct LocalSitePreviewRuntimeStatus: Codable, Hashable, Sendable {
  public var isRunning: Bool
  public var processIdentifier: Int32?
  public var previewURL: URL?
  public var message: String
  public var startedAt: Date?

  public init(
    isRunning: Bool,
    processIdentifier: Int32? = nil,
    previewURL: URL? = nil,
    message: String,
    startedAt: Date? = nil
  ) {
    self.isRunning = isRunning
    self.processIdentifier = processIdentifier
    self.previewURL = previewURL
    self.message = message
    self.startedAt = startedAt
  }

  public static let stopped = LocalSitePreviewRuntimeStatus(
    isRunning: false,
    message: "本地预览未启动。"
  )
}

public final class LocalSitePreviewProcessService {
  private var process: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var activePlan: LocalSitePreviewPlan?
  private var startedAt: Date?

  public init() {}

  static func launchEnvironment(from baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var environment = baseEnvironment
    let existingPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let defaultToolPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin"
    ]

    var seenPaths = Set<String>()
    let mergedPaths = (existingPaths + defaultToolPaths).filter { path in
      seenPaths.insert(path).inserted
    }
    environment["PATH"] = mergedPaths.joined(separator: ":")
    return environment
  }

  public var status: LocalSitePreviewRuntimeStatus {
    guard let process, process.isRunning, let activePlan else {
      return .stopped
    }

    return LocalSitePreviewRuntimeStatus(
      isRunning: true,
      processIdentifier: process.processIdentifier,
      previewURL: activePlan.previewURL,
      message: "本地预览运行中：\(activePlan.previewURL.absoluteString)",
      startedAt: startedAt
    )
  }

  @discardableResult
  public func start(plan: LocalSitePreviewPlan) throws -> LocalSitePreviewRuntimeStatus {
    if let process, process.isRunning {
      return status
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: plan.executablePath)
    process.arguments = plan.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
    process.environment = Self.launchEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    outputPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()

    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    activePlan = plan
    startedAt = Date()

    return status
  }

  public func stop() {
    guard let process else {
      clearProcess()
      return
    }

    if process.isRunning {
      process.terminate()
    }

    clearProcess()
  }

  private func clearProcess() {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    errorPipe = nil
    process = nil
    activePlan = nil
    startedAt = nil
  }
}

public struct LocalSitePreviewService {
  public init() {}

  public func plan(profile: SiteProfile) -> LocalSitePreviewPlan? {
    guard let rootPath = profile.localRepositoryRootURL?.path else {
      return nil
    }

    let executablePath = "/usr/bin/env"
    let arguments: [String]
    let urlString: String
    let notes: [String]

    switch profile.siteKind {
    case .zola:
      arguments = ["zola", "serve", "--drafts"]
      urlString = "http://127.0.0.1:1111"
      notes = ["Zola 默认端口为 1111。", "如果项目自定义端口，请在终端按实际命令启动。"]
    case .hugo:
      arguments = ["hugo", "server", "-D"]
      urlString = "http://127.0.0.1:1313"
      notes = ["Hugo 默认端口为 1313。", "包含草稿预览参数 -D。"]
    case .astro:
      arguments = ["npm", "run", "dev"]
      urlString = "http://127.0.0.1:4321"
      notes = ["Astro 默认 dev server 端口为 4321。", "需要项目已安装 npm 依赖。"]
    case .hexo:
      arguments = ["npm", "run", "server"]
      urlString = "http://127.0.0.1:4000"
      notes = ["Hexo 常见本地端口为 4000。", "如果没有 server script，可改用 hexo server。"]
    case .jekyll:
      arguments = ["bundle", "exec", "jekyll", "serve", "--drafts"]
      urlString = "http://127.0.0.1:4000"
      notes = ["Jekyll 常见本地端口为 4000。", "需要 Ruby bundle 环境可用。"]
    }

    guard let previewURL = URL(string: urlString) else {
      return nil
    }

    return LocalSitePreviewPlan(
      siteKind: profile.siteKind,
      rootPath: rootPath,
      executablePath: executablePath,
      arguments: arguments,
      command: copyableCommand(rootPath: rootPath, arguments: arguments),
      previewURL: previewURL,
      notes: notes
    )
  }

  private func copyableCommand(rootPath: String, arguments: [String]) -> String {
    let command = arguments.map(posixShellQuote).joined(separator: " ")
    return "cd \(posixShellQuote(rootPath)) && \(command)"
  }
}
