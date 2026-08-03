import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum LocalSitePreviewDiagnosticSeverity: String, Codable, Hashable, Sendable {
  case info
  case warning
  case error

  public var isBlocking: Bool { self == .error }
}

public enum LocalSitePreviewDependencyStatus: String, Codable, Hashable, Sendable {
  case available
  case warning
  case missing
  case invalid

  public var isBlocking: Bool {
    self == .missing || self == .invalid
  }
}

public struct LocalSitePreviewDependencyDiagnostic: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let requirement: String
  public let status: LocalSitePreviewDependencyStatus
  public let resolvedPath: String?
  public let detail: String
  public let suggestedAction: String?

  public init(
    id: String,
    name: String,
    requirement: String,
    status: LocalSitePreviewDependencyStatus,
    resolvedPath: String? = nil,
    detail: String,
    suggestedAction: String? = nil
  ) {
    self.id = id
    self.name = name
    self.requirement = requirement
    self.status = status
    self.resolvedPath = resolvedPath
    self.detail = detail
    self.suggestedAction = suggestedAction
  }
}

public struct LocalSitePreviewIssue: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let message: String
  public let severity: LocalSitePreviewDiagnosticSeverity

  public init(
    id: String,
    title: String,
    message: String,
    severity: LocalSitePreviewDiagnosticSeverity
  ) {
    self.id = id
    self.title = title
    self.message = message
    self.severity = severity
  }
}

public struct LocalSitePreviewDiagnostics: Codable, Hashable, Sendable {
  public let siteKind: SiteKind
  public let detectedSiteKind: SiteKind?
  public let rootPath: String
  public let packageManager: String?
  public let scriptName: String?
  public let dependencies: [LocalSitePreviewDependencyDiagnostic]
  public let issues: [LocalSitePreviewIssue]
  public let isReadyToStart: Bool

  public init(
    siteKind: SiteKind,
    rootPath: String,
    detectedSiteKind: SiteKind? = nil,
    packageManager: String? = nil,
    scriptName: String? = nil,
    dependencies: [LocalSitePreviewDependencyDiagnostic] = [],
    issues: [LocalSitePreviewIssue] = [],
    isReadyToStart: Bool? = nil
  ) {
    self.siteKind = siteKind
    self.detectedSiteKind = detectedSiteKind
    self.rootPath = rootPath
    self.packageManager = packageManager
    self.scriptName = scriptName
    self.dependencies = dependencies
    self.issues = issues
    self.isReadyToStart = isReadyToStart ?? !dependencies.contains(where: { $0.status.isBlocking })
      && !issues.contains(where: { $0.severity.isBlocking })
  }

  public var blockingMessages: [String] {
    dependencies.filter { $0.status.isBlocking }.map(\.detail)
      + issues.filter { $0.severity.isBlocking }.map(\.message)
  }

  public var statusTitle: String {
    if isReadyToStart {
      return issues.contains(where: { $0.severity == .warning })
        || dependencies.contains(where: { $0.status == .warning })
        ? "可以启动（有提示）"
        : "依赖检查通过"
    }
    return "需要处理启动问题"
  }
}

public struct LocalSitePreviewPortAllocation: Hashable, Sendable {
  public let port: Int
  public let usesDynamicPort: Bool

  public init(port: Int, usesDynamicPort: Bool) {
    self.port = port
    self.usesDynamicPort = usesDynamicPort
  }
}

public struct LocalSitePreviewPortAllocator: Sendable {
  private let isPortAvailableHandler: @Sendable (Int) -> Bool
  private let dynamicPortHandler: @Sendable () -> Int?

  public init() {
    self.init(
      isPortAvailable: { port in Self.isPortAvailable(port) },
      dynamicPort: { Self.allocateDynamicPort() }
    )
  }

  init(
    isPortAvailable: @escaping @Sendable (Int) -> Bool,
    dynamicPort: @escaping @Sendable () -> Int?
  ) {
    isPortAvailableHandler = isPortAvailable
    dynamicPortHandler = dynamicPort
  }

  public func allocate(
    preferredPort: Int,
    forceDynamicPort: Bool = false
  ) -> LocalSitePreviewPortAllocation? {
    if !forceDynamicPort, isPortAvailableHandler(preferredPort) {
      return LocalSitePreviewPortAllocation(port: preferredPort, usesDynamicPort: false)
    }
    guard let dynamicPort = dynamicPortHandler(), isPortAvailableHandler(dynamicPort) else {
      return nil
    }
    return LocalSitePreviewPortAllocation(port: dynamicPort, usesDynamicPort: true)
  }

  public static func isPortAvailable(_ port: Int) -> Bool {
#if canImport(Darwin)
    guard (1...65_535).contains(port) else { return false }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
#else
    return false
#endif
  }

  public static func allocateDynamicPort() -> Int? {
#if canImport(Darwin)
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { return nil }

    var boundAddress = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(descriptor, sockaddrPointer, &addressLength)
      }
    }
    guard nameResult == 0 else { return nil }
    return Int(UInt16(bigEndian: boundAddress.sin_port))
#else
    return nil
#endif
  }
}

public enum LocalSitePreviewError: LocalizedError, Sendable {
  case invalidRoot(String)
  case dependencyDiagnostics(LocalSitePreviewDiagnostics)
  case portUnavailable(Int)
  case launchFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRoot(let rootPath):
      return "本地预览仓库目录不可用：\(rootPath)"
    case .dependencyDiagnostics(let diagnostics):
      let messages = diagnostics.blockingMessages
      if messages.isEmpty {
        return "本地预览依赖检查未通过。"
      }
      return "本地预览依赖检查未通过：\(messages.joined(separator: "；"))"
    case .portUnavailable(let port):
      return "本地预览端口 \(port) 已被占用，请重新分配端口后再试。"
    case .launchFailed(let message):
      return "本地预览启动失败：\(message)"
    }
  }
}
