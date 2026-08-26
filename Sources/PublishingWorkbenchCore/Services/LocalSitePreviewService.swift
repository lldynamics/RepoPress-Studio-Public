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
  public var usesDynamicPort: Bool
  public var diagnostics: LocalSitePreviewDiagnostics
  public var executionIdentity: LocalSitePreviewExecutionIdentity?

  public var port: Int? {
    previewURL.port
  }

  public init(
    siteKind: SiteKind,
    rootPath: String,
    executablePath: String,
    arguments: [String],
    command: String,
    previewURL: URL,
    notes: [String],
    usesDynamicPort: Bool = false,
    diagnostics: LocalSitePreviewDiagnostics? = nil,
    executionIdentity: LocalSitePreviewExecutionIdentity? = nil
  ) {
    self.siteKind = siteKind
    self.rootPath = rootPath
    self.executablePath = executablePath
    self.arguments = arguments
    self.command = command
    self.previewURL = previewURL
    self.notes = notes
    self.usesDynamicPort = usesDynamicPort
    self.diagnostics = diagnostics ?? LocalSitePreviewDiagnostics(
      siteKind: siteKind,
      rootPath: rootPath
    )
    self.executionIdentity = executionIdentity
  }

  private enum CodingKeys: String, CodingKey {
    case siteKind
    case rootPath
    case executablePath
    case arguments
    case command
    case previewURL
    case notes
    case usesDynamicPort
    case diagnostics
    case executionIdentity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    siteKind = try container.decode(SiteKind.self, forKey: .siteKind)
    rootPath = try container.decode(String.self, forKey: .rootPath)
    executablePath = try container.decode(String.self, forKey: .executablePath)
    arguments = try container.decode([String].self, forKey: .arguments)
    command = try container.decode(String.self, forKey: .command)
    previewURL = try container.decode(URL.self, forKey: .previewURL)
    notes = try container.decode([String].self, forKey: .notes)
    usesDynamicPort = try container.decodeIfPresent(Bool.self, forKey: .usesDynamicPort) ?? false
    diagnostics = try container.decodeIfPresent(LocalSitePreviewDiagnostics.self, forKey: .diagnostics)
      ?? LocalSitePreviewDiagnostics(siteKind: siteKind, rootPath: rootPath)
    executionIdentity = try container.decodeIfPresent(
      LocalSitePreviewExecutionIdentity.self,
      forKey: .executionIdentity
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(siteKind, forKey: .siteKind)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encode(executablePath, forKey: .executablePath)
    try container.encode(arguments, forKey: .arguments)
    try container.encode(command, forKey: .command)
    try container.encode(previewURL, forKey: .previewURL)
    try container.encode(notes, forKey: .notes)
    try container.encode(usesDynamicPort, forKey: .usesDynamicPort)
    try container.encode(diagnostics, forKey: .diagnostics)
    try container.encodeIfPresent(executionIdentity, forKey: .executionIdentity)
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
  private var processGroupIdentifier: Int32?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var activePlan: LocalSitePreviewPlan?
  private var startedAt: Date?
  private let processLock = NSLock()
  private let logCollector = LocalSitePreviewLogCollector(maximumLineCount: 80)
  private let stopExecutor = LocalSitePreviewStopExecutor()
  private let trustStore: LocalSitePreviewTrustStore

  public convenience init() {
    self.init(trustStore: LocalSitePreviewTrustStore())
  }

  init(trustStore: LocalSitePreviewTrustStore) {
    self.trustStore = trustStore
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
    if let port = plan.port, !LocalSitePreviewPortAllocator.isPortAvailable(port) {
      throw LocalSitePreviewError.portUnavailable(port)
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
      Self.isTrustedExecutable(atPath: plan.executablePath)
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
      let gracefulExitDeadline = Date().addingTimeInterval(1)
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
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    errorPipe = nil
    process = nil
    processGroupIdentifier = nil
    activePlan = nil
    startedAt = nil
  }

  private func capturedLogLines() -> [String] {
    logCollector.lines()
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
      siteKind: plan.siteKind
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
    let reportMatchesProfile = repositoryReport.map {
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
    let rootExists = fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) && isDirectory.boolValue
    var executableName = ""
    var baseArguments: [String] = []
    var notes: [String] = []
    var packageManager: String?
    var scriptName: String?
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
    case .hexo:
      packageManager = Self.packageManagerName(in: rootPath)
      executableName = packageManager ?? "npm"
      scriptName = "server"
      baseArguments = ["run", "server"]
      notes = ["Hexo 常见本地端口为 4000。", "如果没有 server script，可改用 hexo server。", "本地预览会执行仓库脚本，请只启动可信仓库。"]
    case .jekyll:
      executableName = "bundle"
      baseArguments = ["exec", "jekyll", "serve", "--drafts"]
      notes = ["Jekyll 常见本地端口为 4000。", "需要 Ruby bundle 环境可用。", "本地预览会执行仓库脚本，请只启动可信仓库。"]
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
      }
    }

    if let scriptName {
      if let data = try? BoundedFileReader.data(
        relativePath: "package.json",
        under: URL(fileURLWithPath: rootPath, isDirectory: true),
        maximumByteCount: Self.maximumPackageJSONByteCount
      ),
         let object = try? JSONSerialization.jsonObject(with: data),
         let package = object as? [String: Any] {
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
      if !fileManager.fileExists(atPath: URL(fileURLWithPath: rootPath).appendingPathComponent("config.toml").path) {
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
        fileManager.fileExists(atPath: URL(fileURLWithPath: rootPath).appendingPathComponent($0).path)
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
    case .astro, .hexo:
      break
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
      if !fileManager.fileExists(atPath: URL(fileURLWithPath: rootPath).appendingPathComponent("Gemfile").path) {
        issues.append(
          LocalSitePreviewIssue(
            id: "gemfile",
            title: "未发现 Gemfile",
            message: "没有找到 Gemfile；bundle exec 可能无法解析站点依赖。",
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
      addPortArguments: allocation?.usesDynamicPort == true
    )
    let previewURL = URL(string: "http://127.0.0.1:\(selectedPort)")!
    let command = copyableCommand(
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
    addPortArguments: Bool
  ) -> [String] {
    guard addPortArguments else { return baseArguments }
    switch siteKind {
    case .zola:
      return baseArguments + ["--interface", "127.0.0.1", "--port", "\(port)"]
    case .hugo:
      return baseArguments + ["--bind", "127.0.0.1", "--port", "\(port)"]
    case .astro:
      if packageManager == "yarn" {
        return baseArguments + ["--host", "127.0.0.1", "--port", "\(port)"]
      }
      return baseArguments + ["--", "--host", "127.0.0.1", "--port", "\(port)"]
    case .vitePress:
      if packageManager == "yarn" {
        return baseArguments + ["--host", "127.0.0.1", "--port", "\(port)"]
      }
      return baseArguments + ["--", "--host", "127.0.0.1", "--port", "\(port)"]
    case .hexo:
      return baseArguments + ["--", "--ip", "127.0.0.1", "--port", "\(port)"]
    case .jekyll:
      return baseArguments + ["--host", "127.0.0.1", "--port", "\(port)"]
    }
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
    case .hexo, .jekyll:
      return 4000
    }
  }

  private static let maximumPackageJSONByteCount = 1 * 1_024 * 1_024

  private static func packageManagerName(in rootPath: String) -> String {
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("pnpm-lock.yaml").path) {
      return "pnpm"
    }
    if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("yarn.lock").path) {
      return "yarn"
    }
    return "npm"
  }

  private func copyableCommand(rootPath: String, executableName: String, arguments: [String]) -> String {
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
