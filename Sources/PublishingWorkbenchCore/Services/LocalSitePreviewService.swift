import Foundation
import PublishingPreviewCore

#if canImport(Darwin)
  import Darwin
#endif

public struct LocalSitePreviewRuntimeStatus: Codable, Hashable, Sendable {
  public var isRunning: Bool
  public var isReachable: Bool
  public var processIdentifier: Int32?
  public var previewURL: URL?
  public var message: String
  public var startedAt: Date?
  public var recentLogLines: [String]
  public var diagnostics: [LocalSitePreviewRuntimeDiagnostic]

  public init(
    isRunning: Bool,
    isReachable: Bool = false,
    processIdentifier: Int32? = nil,
    previewURL: URL? = nil,
    message: String,
    startedAt: Date? = nil,
    recentLogLines: [String] = [],
    diagnostics: [LocalSitePreviewRuntimeDiagnostic] = []
  ) {
    self.isRunning = isRunning
    self.isReachable = isReachable
    self.processIdentifier = processIdentifier
    self.previewURL = previewURL
    self.message = message
    self.startedAt = startedAt
    self.recentLogLines = recentLogLines
    self.diagnostics = diagnostics
  }

  private enum CodingKeys: String, CodingKey {
    case isRunning
    case isReachable
    case processIdentifier
    case previewURL
    case message
    case startedAt
    case recentLogLines
    case diagnostics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isRunning = try container.decode(Bool.self, forKey: .isRunning)
    isReachable = try container.decodeIfPresent(Bool.self, forKey: .isReachable) ?? false
    processIdentifier = try container.decodeIfPresent(Int32.self, forKey: .processIdentifier)
    previewURL = try container.decodeIfPresent(URL.self, forKey: .previewURL)
    message = try container.decode(String.self, forKey: .message)
    startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    recentLogLines = try container.decodeIfPresent([String].self, forKey: .recentLogLines) ?? []
    diagnostics =
      try container.decodeIfPresent([LocalSitePreviewRuntimeDiagnostic].self, forKey: .diagnostics)
      ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(isRunning, forKey: .isRunning)
    try container.encode(isReachable, forKey: .isReachable)
    try container.encodeIfPresent(processIdentifier, forKey: .processIdentifier)
    try container.encodeIfPresent(previewURL, forKey: .previewURL)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(startedAt, forKey: .startedAt)
    try container.encode(recentLogLines, forKey: .recentLogLines)
    try container.encode(diagnostics, forKey: .diagnostics)
  }

  public static let stopped = LocalSitePreviewRuntimeStatus(
    isRunning: false,
    message: "本地预览未启动。"
  )
}

public final class LocalSitePreviewProcessService: @unchecked Sendable {
  private var process: Process?
  private var processGroupIdentifier: Int32?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var activePlan: LocalSitePreviewPlan?
  private var startedAt: Date?
  private let processLock = NSLock()
  private let logCollector = LocalSitePreviewLogCollector(maximumLineCount: 80)
  private let stopExecutor = LocalSitePreviewStopExecutor()
  private let trustStore: LocalSitePreviewTrustStore
  private let isPortAvailable: @Sendable (Int) -> Bool
  private var quartzProbeToken: String?

  public convenience init() {
    self.init(trustStore: LocalSitePreviewTrustStore())
  }

  init(
    trustStore: LocalSitePreviewTrustStore,
    isPortAvailable: @escaping @Sendable (Int) -> Bool = {
      LocalSitePreviewPortAllocator.isPortAvailable($0)
    }
  ) {
    self.trustStore = trustStore
    self.isPortAvailable = isPortAvailable
  }

  private static let systemTrustedToolDirectories = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
  ]

  private static let userTrustedToolDirectoryComponents = [
    [".fnm", "current", "bin"],
    [".local", "share", "fnm", "aliases", "default", "bin"],
    ["Library", "Application Support", "fnm", "aliases", "default", "bin"],
    [".asdf", "shims"],
    [".local", "share", "mise", "shims"],
    [".bun", "bin"],
    [".local", "share", "pnpm"],
    ["Library", "pnpm"],
    [".cargo", "bin"],
    [".volta", "bin"],
    [".rbenv", "shims"],
    ["go", "bin"],
    [".local", "bin"],
  ]

  static var trustedToolDirectories: [String] {
    let environment = ProcessInfo.processInfo.environment
    return trustedToolDirectories(
      homeDirectoryPath: environment["HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path,
      inheritedPATH: environment["PATH"]
    )
  }

  static func trustedToolDirectories(
    homeDirectoryPath: String,
    inheritedPATH: String? = nil,
    fileManager: FileManager = .default
  ) -> [String] {
    let homeURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
      .standardizedFileURL
    let userDirectories = userTrustedToolDirectoryComponents.map { components in
      components.reduce(homeURL) { url, component in
        url.appendingPathComponent(component, isDirectory: true)
      }.path
    }
    let nvmDirectories = nvmToolDirectories(in: homeURL, fileManager: fileManager)
    let allowedDirectories = userDirectories + nvmDirectories + systemTrustedToolDirectories
    let allowedDirectorySet = Set(allowedDirectories)
    let inheritedDirectories =
      inheritedPATH?
      .split(separator: ":")
      .map(String.init)
      .filter { allowedDirectorySet.contains($0) } ?? []

    return (inheritedDirectories + allowedDirectories).reduce(into: []) { result, directory in
      guard !result.contains(directory) else { return }
      result.append(directory)
    }
  }

  private static func nvmToolDirectories(
    in homeURL: URL,
    fileManager: FileManager
  ) -> [String] {
    let versionsURL =
      homeURL
      .appendingPathComponent(".nvm", isDirectory: true)
      .appendingPathComponent("versions", isDirectory: true)
      .appendingPathComponent("node", isDirectory: true)
    let versionURLs =
      (try? fileManager.contentsOfDirectory(
        at: versionsURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    return versionURLs.compactMap { versionURL -> URL? in
      let values = try? versionURL.resourceValues(forKeys: [
        .isDirectoryKey,
        .isSymbolicLinkKey,
      ])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
      let binURL = versionURL.appendingPathComponent("bin", isDirectory: true)
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: binURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { return nil }
      return binURL
    }
    .sorted {
      $0.deletingLastPathComponent().lastPathComponent.compare(
        $1.deletingLastPathComponent().lastPathComponent,
        options: [.caseInsensitive, .numeric]
      ) == .orderedDescending
    }
    .map(\.path)
  }

  static func launchEnvironment(
    from baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let allowedKeys = [
      "HOME",
      "LANG",
      "LC_ALL",
      "LC_CTYPE",
      "LOGNAME",
      "SHELL",
      "TMPDIR",
      "USER",
    ]
    var environment = baseEnvironment.filter { allowedKeys.contains($0.key) }
    let homeDirectoryPath =
      baseEnvironment["HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    environment["PATH"] = trustedToolDirectories(
      homeDirectoryPath: homeDirectoryPath,
      inheritedPATH: baseEnvironment["PATH"]
    ).joined(separator: ":")
    environment["NO_COLOR"] = "1"
    return environment
  }

  public var status: LocalSitePreviewRuntimeStatus {
    processLock.lock()
    defer { processLock.unlock() }
    return statusLocked()
  }

  func quartzReadinessProbe(for plan: LocalSitePreviewPlan) -> (url: URL, token: String)? {
    processLock.lock()
    defer { processLock.unlock() }
    guard plan.siteKind == .quartz,
      activePlan == plan,
      process?.isRunning == true,
      let quartzProbeToken
    else { return nil }
    return (
      plan.previewURL.appendingPathComponent(".__repopress_quartz_probe"),
      quartzProbeToken
    )
  }

  private func statusLocked() -> LocalSitePreviewRuntimeStatus {
    guard let activePlan else {
      return .stopped
    }

    let logLines = capturedLogLines()
    let diagnostics = capturedDiagnostics(rootPath: activePlan.rootPath)
    guard let process, process.isRunning else {
      return LocalSitePreviewRuntimeStatus(
        isRunning: false,
        previewURL: activePlan.previewURL,
        message: "本地预览进程已退出。",
        startedAt: startedAt,
        recentLogLines: logLines,
        diagnostics: diagnostics
      )
    }

    return LocalSitePreviewRuntimeStatus(
      isRunning: true,
      processIdentifier: process.processIdentifier,
      previewURL: activePlan.previewURL,
      message: activePlan.siteKind == .quartz
        && !logLines.contains(QuartzStaticPreviewRunner.readyLogLine)
        ? "Quartz 4 静态快照正在构建，尚未提供预览端口。"
        : "本地预览运行中：\(activePlan.previewURL.absoluteString)",
      startedAt: startedAt,
      recentLogLines: logLines,
      diagnostics: diagnostics
    )
  }

  @discardableResult
  public func start(plan: LocalSitePreviewPlan) throws -> LocalSitePreviewRuntimeStatus {
    processLock.lock()
    defer { processLock.unlock() }
    guard plan.diagnostics.isReadyToStart else {
      throw LocalSitePreviewError.dependencyDiagnostics(plan.diagnostics)
    }
    let identity = try validatedCurrentIdentity(for: plan)
    guard trustStore.isAuthorized(identity) else {
      throw LocalSitePreviewError.authorizationRequired
    }
    if let process, process.isRunning {
      guard activePlan == plan else {
        throw LocalSitePreviewError.executionPlanChanged
      }
      return statusLocked()
    }
    if process != nil {
      clearProcessLocked()
    }
    if plan.siteKind == .quartz {
      // Consume confirmation for this build attempt before any failure path.
      try trustStore.consume(identity)
    }
    if let port = plan.port, !isPortAvailable(port) {
      throw LocalSitePreviewError.portUnavailable(port)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: plan.executablePath)
    process.arguments = plan.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
    var environment = Self.launchEnvironment()
    let probeToken = plan.siteKind == .quartz ? UUID().uuidString : nil
    if let probeToken {
      environment["REPOPRESS_QUARTZ_PREVIEW_TOKEN"] = probeToken
    }
    process.environment = environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let logCollector = logCollector
    outputPipe.fileHandleForReading.readabilityHandler = { handle in
      logCollector.append(handle.availableData, stream: .standardOutput)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      logCollector.append(handle.availableData, stream: .standardError)
    }
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    logCollector.reset()

    do {
      try process.run()
    } catch {
      throw LocalSitePreviewError.launchFailed(error.localizedDescription)
    }

    #if canImport(Darwin)
      if Darwin.setpgid(process.processIdentifier, process.processIdentifier) == 0 {
        processGroupIdentifier = process.processIdentifier
      } else {
        processGroupIdentifier = nil
      }
    #endif

    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    activePlan = plan
    quartzProbeToken = probeToken
    startedAt = Date()

    return statusLocked()
  }

  func authorizationRequest(
    for plan: LocalSitePreviewPlan
  ) throws -> LocalSitePreviewAuthorizationRequest? {
    let identity = try validatedCurrentIdentity(for: plan)
    guard !trustStore.isAuthorized(identity) else { return nil }
    return LocalSitePreviewAuthorizationRequest(
      profileID: identity.profileID,
      fingerprint: identity.fingerprint,
      repositoryPath: identity.canonicalRootPath,
      command: identity.command,
      siteKind: identity.siteKind
    )
  }

  func authorize(
    plan: LocalSitePreviewPlan,
    matching request: LocalSitePreviewAuthorizationRequest
  ) throws {
    let identity = try validatedCurrentIdentity(for: plan)
    guard
      request.profileID == identity.profileID,
      request.fingerprint == identity.fingerprint,
      request.repositoryPath == identity.canonicalRootPath,
      request.command == identity.command,
      request.siteKind == identity.siteKind
    else {
      throw LocalSitePreviewError.executionPlanChanged
    }
    try trustStore.authorize(identity)
    guard trustStore.isAuthorized(identity) else {
      throw LocalSitePreviewError.authorizationStoreUnavailable(
        CoreL10n.text("授权记录写入后无法重新读取。")
      )
    }
  }

  func isExecutionCurrent(for plan: LocalSitePreviewPlan) -> Bool {
    do {
      _ = try validatedCurrentIdentity(for: plan)
      return true
    } catch {
      return false
    }
  }

  func invalidateAuthorization(for plan: LocalSitePreviewPlan) {
    guard let identity = plan.executionIdentity else { return }
    trustStore.invalidate(identity)
  }

  private func validatedCurrentIdentity(
    for plan: LocalSitePreviewPlan
  ) throws -> LocalSitePreviewExecutionIdentity {
    guard let plannedIdentity = plan.executionIdentity else {
      throw LocalSitePreviewError.authorizationRequired
    }
    let canonicalRootPath = URL(fileURLWithPath: plan.rootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    var isDirectory: ObjCBool = false
    guard
      canonicalRootPath == plan.rootPath,
      canonicalRootPath == plannedIdentity.canonicalRootPath,
      FileManager.default.fileExists(atPath: canonicalRootPath, isDirectory: &isDirectory),
      isDirectory.boolValue,
      plan.siteKind == plannedIdentity.siteKind,
      plan.executablePath == plannedIdentity.executablePath,
      plan.arguments == plannedIdentity.arguments,
      plan.command == plannedIdentity.command,
      Self.isTrustedExecutable(atPath: plan.executablePath),
      plan.siteKind != .quartz || QuartzStaticPreviewRunner.isValid(plan: plan)
    else {
      trustStore.invalidate(plannedIdentity)
      throw LocalSitePreviewError.executionPlanChanged
    }

    let currentIdentity: LocalSitePreviewExecutionIdentity
    do {
      currentIdentity = try LocalSitePreviewExecutionFingerprint.currentIdentity(
        for: plan,
        plannedIdentity: plannedIdentity
      )
    } catch {
      trustStore.invalidate(plannedIdentity)
      throw LocalSitePreviewError.executionPlanChanged
    }
    guard currentIdentity == plannedIdentity else {
      trustStore.invalidate(plannedIdentity)
      throw LocalSitePreviewError.executionPlanChanged
    }
    return currentIdentity
  }

  static func isTrustedExecutable(
    atPath path: String,
    homeDirectoryPath: String = ProcessInfo.processInfo.environment["HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path,
    inheritedPATH: String? = ProcessInfo.processInfo.environment["PATH"],
    fileManager: FileManager = .default
  ) -> Bool {
    let standardizedURL = URL(fileURLWithPath: path).standardizedFileURL
    let parentPath = standardizedURL.deletingLastPathComponent().path
    let trustedDirectories = trustedToolDirectories(
      homeDirectoryPath: homeDirectoryPath,
      inheritedPATH: inheritedPATH,
      fileManager: fileManager
    )
    guard trustedDirectories.contains(parentPath) else { return false }
    let resolvedURL = standardizedURL.resolvingSymlinksInPath().standardizedFileURL
    let homeURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let trustedUserRoots = [
      [".local"],
      [".cargo"],
      [".bun"],
      [".fnm"],
      [".asdf"],
      [".nvm"],
      [".volta"],
      [".rbenv"],
      ["go"],
      ["Library", "Application Support", "fnm"],
      ["Library", "pnpm"],
    ].map { components in
      components.reduce(homeURL) { url, component in
        url.appendingPathComponent(component, isDirectory: true)
      }.path
    }
    let trustedResolvedRoots =
      trustedUserRoots + [
        "/opt/homebrew",
        "/usr/local",
        "/usr",
        "/bin",
        "/sbin",
      ]
    guard
      trustedResolvedRoots.contains(where: { rootPath in
        resolvedURL.path == rootPath || resolvedURL.path.hasPrefix(rootPath + "/")
      }), fileManager.isExecutableFile(atPath: resolvedURL.path)
    else {
      return false
    }
    #if canImport(Darwin)
      var metadata = stat()
      guard resolvedURL.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
        return false
      }
      return (metadata.st_mode & S_IFMT) == S_IFREG
    #else
      let values = try? resolvedURL.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ])
      return values?.isRegularFile == true && values?.isSymbolicLink != true
    #endif
  }

  public func stop() {
    processLock.lock()
    defer { processLock.unlock() }
    stopLocked()
  }

  public func stopAsync() async {
    await stopExecutor.stop(service: self)
  }

  private func stopLocked() {
    guard let process else {
      clearProcessLocked()
      return
    }

    if process.isRunning {
      #if canImport(Darwin)
        if let processGroupIdentifier {
          Darwin.kill(-processGroupIdentifier, SIGTERM)
        } else {
          process.terminate()
        }
      #else
        process.terminate()
      #endif
      let gracefulExitDeadline = Date().addingTimeInterval(
        activePlan?.siteKind == .quartz ? 3 : 1
      )
      while process.isRunning, Date() < gracefulExitDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning {
        #if canImport(Darwin)
          if let processGroupIdentifier {
            Darwin.kill(-processGroupIdentifier, SIGKILL)
          } else {
            Darwin.kill(process.processIdentifier, SIGKILL)
          }
        #endif
      }
    }

    if process.isRunning {
      process.waitUntilExit()
    }

    clearProcessLocked()
  }

  private func clearProcessLocked() {
    if activePlan?.siteKind == .quartz, let process {
      QuartzStaticPreviewRunner.removeTemporaryDirectories(
        processIdentifier: process.processIdentifier
      )
    }
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    errorPipe = nil
    process = nil
    processGroupIdentifier = nil
    activePlan = nil
    quartzProbeToken = nil
    startedAt = nil
  }

  private func capturedLogLines() -> [String] {
    logCollector.lines()
  }

  private func capturedDiagnostics(rootPath: String) -> [LocalSitePreviewRuntimeDiagnostic] {
    LocalSitePreviewDiagnosticParser.diagnostics(
      lines: logCollector.lines(includePendingLine: true),
      rootPath: rootPath
    )
  }
}

/// Runs the blocking process termination path away from the caller's actor.
/// The service remains lock-protected because synchronous start/status/stop
/// calls and the application termination hook still share the same instance.
private actor LocalSitePreviewStopExecutor {
  func stop(service: LocalSitePreviewProcessService) {
    service.stop()
  }
}

final class LocalSitePreviewLogCollector: @unchecked Sendable {
  private static let maximumLineBytes = 4_096
  enum Stream {
    case standardOutput
    case standardError
  }

  private let lock = NSLock()
  private let maximumLineCount: Int
  private var recentLogLines: [String] = []
  private var pendingOutputData = Data()
  private var pendingErrorData = Data()

  init(maximumLineCount: Int) {
    self.maximumLineCount = maximumLineCount
  }

  func append(_ data: Data, stream: Stream = .standardOutput) {
    lock.lock()
    defer { lock.unlock() }
    var pendingData = stream == .standardOutput ? pendingOutputData : pendingErrorData
    pendingData.append(data)

    while let newlineIndex = pendingData.firstIndex(of: 0x0A) {
      var lineData = pendingData.prefix(upTo: newlineIndex)
      pendingData.removeSubrange(...newlineIndex)
      if lineData.last == 0x0D {
        lineData.removeLast()
      }
      appendLineLocked(String(decoding: lineData.prefix(Self.maximumLineBytes), as: UTF8.self))
    }
    if pendingData.count > Self.maximumLineBytes {
      pendingData.removeAll(keepingCapacity: true)
    }
    if stream == .standardOutput {
      pendingOutputData = pendingData
    } else {
      pendingErrorData = pendingData
    }
  }

  func reset() {
    lock.lock()
    recentLogLines = []
    pendingOutputData = Data()
    pendingErrorData = Data()
    lock.unlock()
  }

  func lines(includePendingLine: Bool = false) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    guard includePendingLine else { return recentLogLines }
    return recentLogLines
      + [pendingOutputData, pendingErrorData].compactMap { data in
        guard !data.isEmpty else { return nil }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return line.isEmpty ? nil : line
      }
  }

  private func appendLineLocked(_ line: String) {
    guard !line.isEmpty else { return }
    recentLogLines.append(line)
    if recentLogLines.count > maximumLineCount {
      recentLogLines.removeFirst(recentLogLines.count - maximumLineCount)
    }
  }
}

public struct LocalSitePreviewService {
  private let executableResolver: (String) -> String?
  private let portAllocator: LocalSitePreviewPortAllocator

  public init(portAllocator: LocalSitePreviewPortAllocator = LocalSitePreviewPortAllocator()) {
    executableResolver = Self.resolveTrustedExecutable(named:)
    self.portAllocator = portAllocator
  }

  init(
    executableResolver: @escaping (String) -> String?,
    portAllocator: LocalSitePreviewPortAllocator = LocalSitePreviewPortAllocator()
  ) {
    self.executableResolver = executableResolver
    self.portAllocator = portAllocator
  }

  public func previewURL(for draft: ArticleDraft, profile: SiteProfile) -> URL? {
    guard let plan = plan(profile: profile) else { return nil }
    return previewURL(for: draft, profile: profile, plan: plan)
  }

  public func previewURL(
    for draft: ArticleDraft,
    profile: SiteProfile,
    plan: LocalSitePreviewPlan
  ) -> URL? {
    return SiteArticleURLResolver().url(
      baseURL: plan.previewURL,
      markdownPath: profile.markdownPath(for: draft),
      profile: profile,
      permalink: draft.permalink
    )
  }

  public func plan(profile: SiteProfile) -> LocalSitePreviewPlan? {
    plan(profile: profile, repositoryReport: nil)
  }

  public func plan(
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport?,
    preferredPort: Int? = nil,
    forceDynamicPort: Bool = false
  ) -> LocalSitePreviewPlan? {
    guard let configuredRootURL = profile.localRepositoryRootURL else {
      return nil
    }

    let configuredRootPath = configuredRootURL.standardizedFileURL.resolvingSymlinksInPath().path
    let reportMatchesProfile =
      repositoryReport.map {
        URL(fileURLWithPath: $0.rootPath, isDirectory: true)
          .standardizedFileURL
          .resolvingSymlinksInPath()
          .path == configuredRootPath
      } ?? false
    let rootPath = configuredRootPath
    let detectedSiteKind = reportMatchesProfile ? repositoryReport?.detectedKind : nil
    let siteKind = detectedSiteKind ?? profile.siteKind

    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    let rootExists =
      fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
    var executableName = ""
    var baseArguments: [String] = []
    var notes: [String] = []
    var packageManager: String?
    var scriptName: String?
    var quartzNodePath: String?
    var dependencies: [LocalSitePreviewDependencyDiagnostic] = []
    var issues: [LocalSitePreviewIssue] = []

    switch siteKind {
    case .zola:
      executableName = "zola"
      baseArguments = ["serve", "--drafts"]
      notes = ["Zola 默认端口为 1111。", "如果项目自定义端口，请在终端按实际命令启动。"]
    case .hugo:
      executableName = "hugo"
      baseArguments = ["server", "-D"]
      notes = ["Hugo 默认端口为 1313。", "包含草稿预览参数 -D。"]
    case .astro:
      packageManager = Self.packageManagerName(in: rootPath)
      executableName = packageManager ?? "npm"
      scriptName = "dev"
      baseArguments = ["run", "dev"]
      notes = ["Astro 默认 dev server 端口为 4321。", "需要项目已安装 npm 依赖。", "本地预览会执行仓库脚本，请只启动可信仓库。"]
    case .vitePress:
      packageManager = Self.packageManagerName(in: rootPath)
      executableName = packageManager ?? "npm"
      scriptName = "dev"
      baseArguments = ["run", "dev"]
      notes = ["VitePress 默认 dev server 端口为 5173。", "需要项目已安装 npm 依赖。", "本地预览会执行仓库脚本，请只启动可信仓库。"]
    case .nextJS:
      packageManager = Self.packageManagerName(in: rootPath)
      executableName = packageManager ?? "npm"
      scriptName = "dev"
      baseArguments = ["run", "dev"]
      notes = [
        "Next.js 默认 dev server 端口为 3000。", "兼容 Contentlayer / Velite 内容仓库。",
        "本地预览会执行仓库脚本，请只启动可信仓库。",
      ]
    case .quartz:
      executableName = "python3"
      quartzNodePath = executableResolver("node")
      baseArguments = [
        "-I", "-c", QuartzStaticPreviewRunner.pythonSource, rootPath, quartzNodePath ?? "",
      ]
      notes = [
        "Quartz 4 在临时副本中构建静态快照，再由本机回环 HTTP 服务提供预览。",
        "源文件变化后停止快照；再次启动需确认。不会启动 Quartz 自带的 HTTP 或 WebSocket 服务。",
      ]
    case .foam:
      return nil
    case .hexo:
      packageManager = Self.packageManagerName(in: rootPath)
      executableName = packageManager ?? "npm"
      scriptName = "server"
      baseArguments = ["run", "server"]
      notes = [
        "Hexo 常见本地端口为 4000。", "如果没有 server script，可改用 hexo server。", "本地预览会执行仓库脚本，请只启动可信仓库。",
      ]
    case .jekyll:
      executableName = "bundle"
      baseArguments = ["exec", "jekyll", "serve", "--drafts"]
      notes = ["Jekyll 常见本地端口为 4000。", "需要 Ruby bundle 环境可用。", "本地预览会执行仓库脚本，请只启动可信仓库。"]
    case .docusaurus:
      packageManager = Self.packageManagerName(in: rootPath)
      executableName = packageManager ?? "npm"
      scriptName = "start"
      baseArguments = ["run", "start"]
      notes = ["Docusaurus 默认 dev server 端口为 3000。", "需要项目已安装 npm 依赖。", "本地预览会执行仓库脚本，请只启动可信仓库。"]
    case .mkDocs:
      executableName = "mkdocs"
      baseArguments = ["serve"]
      notes = ["MkDocs 默认 dev server 端口为 8000。", "本地预览会绑定到本机回环地址。"]
    }

    if !rootExists {
      issues.append(
        LocalSitePreviewIssue(
          id: "root",
          title: "仓库目录不可用",
          message: "找不到本地仓库目录：\(rootPath)",
          severity: .error
        )
      )
    }

    let resolvedExecutablePath = executableResolver(executableName)
    let executablePath = URL(
      fileURLWithPath: resolvedExecutablePath
        ?? Self.trustedExecutableCandidates(named: executableName).first
        ?? executableName
    ).standardizedFileURL.path
    if let resolvedPath = resolvedExecutablePath {
      dependencies.append(
        LocalSitePreviewDependencyDiagnostic(
          id: "executable",
          name: executableName,
          requirement: "启动命令",
          status: .available,
          resolvedPath: resolvedPath,
          detail: "已找到可执行文件。"
        )
      )
    } else {
      dependencies.append(
        LocalSitePreviewDependencyDiagnostic(
          id: "executable",
          name: executableName,
          requirement: "启动命令",
          status: .missing,
          detail: "在受信任的本地工具目录中没有找到 \(executableName)。",
          suggestedAction: "安装 \(executableName)，或把它加入受信任的工具目录。"
        )
      )
    }

    if siteKind == .quartz {
      let trustedNode = quartzNodePath.flatMap { nodePath in
        LocalSitePreviewProcessService.isTrustedExecutable(atPath: nodePath) ? nodePath : nil
      }
      dependencies.append(
        LocalSitePreviewDependencyDiagnostic(
          id: "quartz-node",
          name: "node",
          requirement: "Quartz 4 静态构建",
          status: trustedNode == nil ? .missing : .available,
          resolvedPath: trustedNode,
          detail: trustedNode == nil ? "未找到受信任的 Node.js。" : "已找到受信任的 Node.js。"
        )
      )
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      if !fileManager.fileExists(
        atPath: rootURL.appendingPathComponent("quartz/bootstrap-cli.mjs").path
      ) {
        issues.append(
          LocalSitePreviewIssue(
            id: "quartz-cli",
            title: "未发现 Quartz 4 命令入口",
            message: "仓库缺少 quartz/bootstrap-cli.mjs。",
            severity: .error
          )
        )
      }
      if !fileManager.fileExists(atPath: rootURL.appendingPathComponent("node_modules").path) {
        dependencies.append(
          LocalSitePreviewDependencyDiagnostic(
            id: "quartz-node-modules",
            name: "node_modules",
            requirement: "Quartz 4 已安装依赖",
            status: .missing,
            detail: "仓库缺少已安装的 Node 依赖。"
          )
        )
      }
    }

    let manifestSnapshot: LocalSitePreviewExecutionFingerprint.ManifestSnapshot?
    do {
      manifestSnapshot = try LocalSitePreviewExecutionFingerprint.captureManifest(
        rootPath: rootPath,
        siteKind: siteKind
      )
    } catch {
      manifestSnapshot = nil
      if siteKind == .jekyll {
        issues.append(
          LocalSitePreviewIssue(
            id: "jekyll-manifest",
            title: CoreL10n.text("无法安全读取 Jekyll 配置"),
            message: CoreL10n.format(
              "Gemfile 或 Gemfile.lock 无法在不跟随符号链接的情况下有界读取：%@",
              error.localizedDescription
            ),
            severity: .error
          )
        )
      } else if siteKind == .quartz {
        issues.append(
          LocalSitePreviewIssue(
            id: "execution-manifest",
            title: CoreL10n.text("无法安全读取预览配置"),
            message: CoreL10n.format(
              "站点配置无法在不跟随符号链接的情况下有界读取：%@",
              error.localizedDescription
            ),
            severity: .error
          )
        )
      }
    }

    if let scriptName {
      if let data = try? BoundedFileReader.data(
        relativePath: "package.json",
        under: URL(fileURLWithPath: rootPath, isDirectory: true),
        maximumByteCount: Self.maximumPackageJSONByteCount
      ),
        let object = try? JSONSerialization.jsonObject(with: data),
        let package = object as? [String: Any]
      {
        let scripts = (package["scripts"] as? [String: Any]) ?? [:]
        if scripts[scriptName] != nil {
          dependencies.append(
            LocalSitePreviewDependencyDiagnostic(
              id: "script",
              name: scriptName,
              requirement: "\(packageManager ?? "npm") run \(scriptName)",
              status: .available,
              detail: "已找到站点启动脚本。"
            )
          )
        } else {
          dependencies.append(
            LocalSitePreviewDependencyDiagnostic(
              id: "script",
              name: scriptName,
              requirement: "\(packageManager ?? "npm") run \(scriptName)",
              status: .invalid,
              detail: "package.json 中没有 \(scriptName) 脚本。",
              suggestedAction: "在 package.json 增加站点开发脚本，或选择正确的站点类型。"
            )
          )
        }
      } else {
        dependencies.append(
          LocalSitePreviewDependencyDiagnostic(
            id: "package-json",
            name: "package.json",
            requirement: "Node 项目配置",
            status: .invalid,
            detail: "没有找到可读取的 package.json，无法确认 \(scriptName) 脚本。",
            suggestedAction: "确认仓库根目录包含有效的 package.json。"
          )
        )
      }

      let nodeModulesURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
      if !fileManager.fileExists(atPath: nodeModulesURL.path) {
        dependencies.append(
          LocalSitePreviewDependencyDiagnostic(
            id: "node-modules",
            name: "node_modules",
            requirement: "已安装的 Node 依赖",
            status: .warning,
            detail: "没有发现 node_modules；启动时可能需要先执行依赖安装。",
            suggestedAction: "在仓库目录执行对应包管理器的 install。"
          )
        )
      }
    }

    switch siteKind {
    case .zola:
      if !fileManager.fileExists(
        atPath: URL(fileURLWithPath: rootPath).appendingPathComponent("config.toml").path)
      {
        issues.append(
          LocalSitePreviewIssue(
            id: "zola-config",
            title: "未发现 Zola 配置",
            message: "仓库根目录没有 config.toml；如果使用自定义配置，请确认启动目录。",
            severity: .warning
          )
        )
      }
    case .hugo:
      let hasHugoConfig = ["hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json"].contains {
        fileManager.fileExists(
          atPath: URL(fileURLWithPath: rootPath).appendingPathComponent($0).path)
      }
      if !hasHugoConfig {
        issues.append(
          LocalSitePreviewIssue(
            id: "hugo-config",
            title: "未发现 Hugo 配置",
            message: "仓库根目录没有常见 Hugo 配置文件。",
            severity: .warning
          )
        )
      }
    case .astro, .hexo, .foam:
      break
    case .nextJS:
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      let hasConfig = [
        "contentlayer.config.ts",
        "contentlayer.config.js",
        "contentlayer.config.mjs",
        "contentlayer.config.cjs",
        "velite.config.ts",
        "velite.config.mts",
        "velite.config.js",
        "velite.config.mjs",
        "velite.config.cjs",
        "next.config.ts",
        "next.config.mjs",
        "next.config.js",
      ].contains { fileManager.fileExists(atPath: rootURL.appendingPathComponent($0).path) }
      if !hasConfig {
        issues.append(
          LocalSitePreviewIssue(
            id: "nextjs-config",
            title: "未发现 Next.js 内容配置",
            message: "仓库中没有常见的 Next.js、Contentlayer 或 Velite 配置文件。",
            severity: .warning
          )
        )
      }
    case .quartz:
      if !fileManager.fileExists(
        atPath: URL(fileURLWithPath: rootPath).appendingPathComponent("quartz.config.ts").path
      ) {
        issues.append(
          LocalSitePreviewIssue(
            id: "quartz-config",
            title: "未发现 Quartz 配置",
            message: "仓库根目录没有 quartz.config.ts。",
            severity: .error
          )
        )
      }
    case .vitePress:
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      let hasConfig = [
        "docs/.vitepress/config.mts",
        "docs/.vitepress/config.ts",
        ".vitepress/config.mts",
        ".vitepress/config.ts",
      ].contains { fileManager.fileExists(atPath: rootURL.appendingPathComponent($0).path) }
      if !hasConfig {
        issues.append(
          LocalSitePreviewIssue(
            id: "vitepress-config",
            title: "未发现 VitePress 配置",
            message: "仓库中没有常见的 .vitepress/config 配置文件。",
            severity: .warning
          )
        )
      }
    case .jekyll:
      if !fileManager.fileExists(
        atPath: URL(fileURLWithPath: rootPath).appendingPathComponent("Gemfile").path)
      {
        issues.append(
          LocalSitePreviewIssue(
            id: "gemfile",
            title: "未发现 Gemfile",
            message: "没有找到 Gemfile；bundle exec 可能无法解析站点依赖。",
            severity: .warning
          )
        )
      }
    case .docusaurus:
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      let hasConfig = [
        "docusaurus.config.js", "docusaurus.config.ts", "docusaurus.config.mjs",
        "docusaurus.config.cjs",
      ].contains { fileManager.fileExists(atPath: rootURL.appendingPathComponent($0).path) }
      if !hasConfig {
        issues.append(
          LocalSitePreviewIssue(
            id: "docusaurus-config",
            title: "未发现 Docusaurus 配置",
            message: "仓库根目录没有常见的 docusaurus.config 配置文件。",
            severity: .warning
          )
        )
      }
    case .mkDocs:
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      let hasConfig = ["mkdocs.yml", "mkdocs.yaml"].contains {
        fileManager.fileExists(atPath: rootURL.appendingPathComponent($0).path)
      }
      if !hasConfig {
        issues.append(
          LocalSitePreviewIssue(
            id: "mkdocs-config",
            title: "未发现 MkDocs 配置",
            message: "仓库根目录没有 mkdocs.yml 或 mkdocs.yaml。",
            severity: .warning
          )
        )
      }
    }

    if let detectedSiteKind, detectedSiteKind != profile.siteKind {
      issues.append(
        LocalSitePreviewIssue(
          id: "detected-site-kind",
          title: "已按扫描结果选择站点类型",
          message: "配置为 \(profile.siteKind.displayName)，仓库扫描为 \(detectedSiteKind.displayName)。",
          severity: .warning
        )
      )
    }

    let defaultPort = preferredPort ?? Self.defaultPort(for: siteKind)
    let allocation = portAllocator.allocate(
      preferredPort: defaultPort,
      forceDynamicPort: forceDynamicPort
    )
    let selectedPort = allocation?.port ?? defaultPort
    if allocation == nil {
      issues.append(
        LocalSitePreviewIssue(
          id: "port",
          title: "没有可用预览端口",
          message: "默认端口 \(defaultPort) 已被占用，且没有分配到新的本地端口。",
          severity: .error
        )
      )
    } else if allocation?.usesDynamicPort == true {
      notes.append("默认端口 \(defaultPort) 已被占用，本次预览自动改用端口 \(selectedPort)。")
    }

    let arguments = arguments(
      baseArguments: baseArguments,
      siteKind: siteKind,
      packageManager: packageManager,
      port: selectedPort,
      includesPortArgument: allocation?.usesDynamicPort == true
    )
    let previewURL = URL(string: "http://127.0.0.1:\(selectedPort)")!
    let command =
      siteKind == .quartz
      ? "cd \(posixShellQuote(rootPath)) && node quartz/bootstrap-cli.mjs build --output <temporary> && python3 <loopback-static-preview> \(selectedPort)"
      : copyableCommand(
        rootPath: rootPath,
        executableName: executableName,
        arguments: arguments
      )
    let diagnostics = LocalSitePreviewDiagnostics(
      siteKind: siteKind,
      rootPath: rootPath,
      detectedSiteKind: detectedSiteKind,
      packageManager: packageManager,
      scriptName: scriptName,
      dependencies: dependencies,
      issues: issues
    )
    let executionIdentity: LocalSitePreviewExecutionIdentity?
    do {
      executionIdentity = try LocalSitePreviewExecutionFingerprint.makeIdentity(
        profileID: profile.id,
        rootPath: rootPath,
        siteKind: siteKind,
        executablePath: executablePath,
        arguments: arguments,
        command: command,
        manifestSnapshot: manifestSnapshot
      )
    } catch {
      executionIdentity = nil
    }

    return LocalSitePreviewPlan(
      siteKind: siteKind,
      rootPath: rootPath,
      executablePath: executablePath,
      arguments: arguments,
      command: command,
      previewURL: previewURL,
      notes: notes,
      usesDynamicPort: allocation?.usesDynamicPort == true,
      diagnostics: diagnostics,
      executionIdentity: executionIdentity
    )
  }

  private func arguments(
    baseArguments: [String],
    siteKind: SiteKind,
    packageManager: String?,
    port: Int,
    includesPortArgument: Bool
  ) -> [String] {
    switch siteKind {
    case .zola:
      return baseArguments + ["--interface", "127.0.0.1"]
        + portArguments(port, included: includesPortArgument)
    case .hugo:
      return baseArguments + ["--bind", "127.0.0.1"]
        + portArguments(port, included: includesPortArgument)
    case .astro, .vitePress, .docusaurus:
      return baseArguments
        + forwardedPackageScriptArguments(
          ["--host", "127.0.0.1"]
            + portArguments(port, included: includesPortArgument),
          packageManager: packageManager
        )
    case .nextJS:
      return baseArguments
        + forwardedPackageScriptArguments(
          ["--hostname", "127.0.0.1"]
            + portArguments(port, included: includesPortArgument),
          packageManager: packageManager
        )
    case .hexo:
      return baseArguments
        + forwardedPackageScriptArguments(
          ["--ip", "127.0.0.1"]
            + portArguments(port, included: includesPortArgument),
          packageManager: packageManager
        )
    case .jekyll:
      return baseArguments + ["--host", "127.0.0.1"]
        + portArguments(port, included: includesPortArgument)
    case .mkDocs:
      return baseArguments + ["--dev-addr", "127.0.0.1:\(port)"]
    case .quartz:
      return baseArguments + [
        String(port), String(ProcessInfo.processInfo.processIdentifier),
      ]
    case .foam:
      return baseArguments
    }
  }

  private func portArguments(_ port: Int, included: Bool) -> [String] {
    included ? ["--port", "\(port)"] : []
  }

  private func forwardedPackageScriptArguments(
    _ arguments: [String],
    packageManager: String?
  ) -> [String] {
    packageManager == "yarn" ? arguments : ["--"] + arguments
  }

  private static func defaultPort(for siteKind: SiteKind) -> Int {
    switch siteKind {
    case .zola:
      return 1111
    case .hugo:
      return 1313
    case .astro:
      return 4321
    case .vitePress:
      return 5173
    case .nextJS, .foam, .docusaurus:
      return 3000
    case .quartz:
      return 8080
    case .hexo, .jekyll:
      return 4000
    case .mkDocs:
      return 8000
    }
  }

  private static let maximumPackageJSONByteCount = 1 * 1_024 * 1_024

  private static func packageManagerName(in rootPath: String) -> String {
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("pnpm-lock.yaml").path)
    {
      return "pnpm"
    }
    if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("yarn.lock").path) {
      return "yarn"
    }
    return "npm"
  }

  private func copyableCommand(rootPath: String, executableName: String, arguments: [String])
    -> String
  {
    let command = ([executableName] + arguments).map(posixShellQuote).joined(separator: " ")
    return "cd \(posixShellQuote(rootPath)) && \(command)"
  }

  private static func resolveTrustedExecutable(named name: String) -> String? {
    trustedExecutableCandidates(named: name).first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  private static func trustedExecutableCandidates(named name: String) -> [String] {
    LocalSitePreviewProcessService.trustedToolDirectories.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path
    }
  }
}
