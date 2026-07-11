import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
  public var isReachable: Bool
  public var processIdentifier: Int32?
  public var previewURL: URL?
  public var message: String
  public var startedAt: Date?
  public var recentLogLines: [String]

  public init(
    isRunning: Bool,
    isReachable: Bool = false,
    processIdentifier: Int32? = nil,
    previewURL: URL? = nil,
    message: String,
    startedAt: Date? = nil,
    recentLogLines: [String] = []
  ) {
    self.isRunning = isRunning
    self.isReachable = isReachable
    self.processIdentifier = processIdentifier
    self.previewURL = previewURL
    self.message = message
    self.startedAt = startedAt
    self.recentLogLines = recentLogLines
  }

  public static let stopped = LocalSitePreviewRuntimeStatus(
    isRunning: false,
    message: "本地预览未启动。"
  )
}

public final class LocalSitePreviewProcessService: @unchecked Sendable {
  private var process: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var activePlan: LocalSitePreviewPlan?
  private var startedAt: Date?
  private let processLock = NSLock()
  private let logCollector = LocalSitePreviewLogCollector(maximumLineCount: 80)

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
    processLock.lock()
    defer { processLock.unlock() }
    return statusLocked()
  }

  private func statusLocked() -> LocalSitePreviewRuntimeStatus {
    guard let activePlan else {
      return .stopped
    }

    let logLines = capturedLogLines()
    guard let process, process.isRunning else {
      return LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: activePlan.previewURL,
        message: "本地预览进程已退出。",
        startedAt: startedAt,
        recentLogLines: logLines
      )
    }

    return LocalSitePreviewRuntimeStatus(
      isRunning: true,
      processIdentifier: process.processIdentifier,
      previewURL: activePlan.previewURL,
      message: "本地预览运行中：\(activePlan.previewURL.absoluteString)",
      startedAt: startedAt,
      recentLogLines: logLines
    )
  }

  @discardableResult
  public func start(plan: LocalSitePreviewPlan) throws -> LocalSitePreviewRuntimeStatus {
    processLock.lock()
    defer { processLock.unlock() }
    if let process, process.isRunning {
      return statusLocked()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: plan.executablePath)
    process.arguments = plan.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
    process.environment = Self.launchEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let logCollector = logCollector
    outputPipe.fileHandleForReading.readabilityHandler = { handle in
      logCollector.append(handle.availableData)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      logCollector.append(handle.availableData)
    }
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    logCollector.reset()

    try process.run()

    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    activePlan = plan
    startedAt = Date()

    return statusLocked()
  }

  public func stop() {
    processLock.lock()
    defer { processLock.unlock() }
    stopLocked()
  }

  public func stopAsync() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.stop()
        continuation.resume()
      }
    }
  }

  private func stopLocked() {
    guard let process else {
      clearProcessLocked()
      return
    }

    if process.isRunning {
      process.terminate()
      let gracefulExitDeadline = Date().addingTimeInterval(1)
      while process.isRunning, Date() < gracefulExitDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning {
#if canImport(Darwin)
        Darwin.kill(process.processIdentifier, SIGKILL)
#endif
      }
    }

    if process.isRunning {
      process.waitUntilExit()
    }

    clearProcessLocked()
  }

  private func clearProcessLocked() {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    errorPipe = nil
    process = nil
    activePlan = nil
    startedAt = nil
  }

  private func capturedLogLines() -> [String] {
    logCollector.lines()
  }
}

private final class LocalSitePreviewLogCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumLineCount: Int
  private var recentLogLines: [String] = []

  init(maximumLineCount: Int) {
    self.maximumLineCount = maximumLineCount
  }

  func append(_ data: Data) {
    guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else {
      return
    }

    let lines = output
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return }

    lock.lock()
    recentLogLines.append(contentsOf: lines)
    if recentLogLines.count > maximumLineCount {
      recentLogLines.removeFirst(recentLogLines.count - maximumLineCount)
    }
    lock.unlock()
  }

  func reset() {
    lock.lock()
    recentLogLines = []
    lock.unlock()
  }

  func lines() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return recentLogLines
  }
}

public struct LocalSitePreviewService {
  public init() {}

  public func previewURL(for draft: ArticleDraft, profile: SiteProfile) -> URL? {
    guard let plan = plan(profile: profile) else { return nil }
    return SiteArticleURLResolver().url(
      baseURL: plan.previewURL,
      markdownPath: profile.markdownPath(for: draft),
      siteKind: profile.siteKind
    )
  }

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
