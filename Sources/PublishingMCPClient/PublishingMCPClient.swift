import CryptoKit
import Darwin
import Dispatch
import Foundation
import MCP
import PublishingAICore
import PublishingWorkbenchCore

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

/// Host-owned key used to bind sensitive MCP launch authority without turning
/// the public catalog revision into an offline verifier for low-entropy
/// environment values. Hosts should persist the same 32 random bytes in their
/// credential store when reviewed MCP bindings must survive relaunches.
public struct PublishingMCPAuthorityKey: Hashable, Sendable {
  fileprivate let rawRepresentation: Data

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == 32 else {
      throw PublishingMCPClientError.invalidConfiguration
    }
    self.rawRepresentation = rawRepresentation
  }
}

private struct PublishingMCPFilesystemIdentity: Hashable, Sendable {
  let resolvedPath: String
  let deviceID: UInt64
  let fileID: UInt64
  let isDirectory: Bool
  let byteCount: UInt64?
  let modificationDate: Date?
  let contentSHA256: String?

  static func capture(
    _ url: URL,
    expectingDirectory: Bool
  ) -> PublishingMCPFilesystemIdentity? {
    guard url.isFileURL else { return nil }
    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
      let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
      let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
      let type = attributes[.type] as? FileAttributeType
    else {
      return nil
    }
    let isDirectory = type == .typeDirectory
    guard isDirectory == expectingDirectory else { return nil }
    let contentSHA256 = isDirectory ? nil : fileSHA256(at: resolvedURL)
    guard isDirectory || contentSHA256 != nil,
      let finalAttributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
      (finalAttributes[.systemNumber] as? NSNumber)?.uint64Value == deviceID,
      (finalAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == fileID,
      finalAttributes[.type] as? FileAttributeType == type,
      isDirectory
        || (finalAttributes[.size] as? NSNumber)?.uint64Value
          == (attributes[.size] as? NSNumber)?.uint64Value,
      isDirectory
        || finalAttributes[.modificationDate] as? Date
          == attributes[.modificationDate] as? Date
    else {
      return nil
    }
    return PublishingMCPFilesystemIdentity(
      resolvedPath: resolvedURL.path,
      deviceID: deviceID,
      fileID: fileID,
      isDirectory: isDirectory,
      byteCount: isDirectory ? nil : (attributes[.size] as? NSNumber)?.uint64Value,
      modificationDate: isDirectory ? nil : attributes[.modificationDate] as? Date,
      contentSHA256: contentSHA256
    )
  }

  private static func fileSHA256(at url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Host-owned configuration for one trusted local MCP server.  The executable
/// and arguments are structured values: this module never invokes a shell.
public struct PublishingMCPSourceConfiguration: Hashable, Sendable {
  public let sourceID: String
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectoryURL: URL?
  /// Additional script, package-entry, or configuration files whose exact
  /// bytes are part of this launch authority. Existing regular-file arguments
  /// are included automatically; callers must list indirect artifacts such as
  /// files loaded through an interpreter module name.
  public let pinnedLaunchArtifactURLs: [URL]
  /// These are the only caller-supplied environment values passed to the child.
  /// No ambient API keys, tokens, or other process environment is inherited.
  public let environmentOverrides: [String: String]
  /// A host-generated revision. A changed value invalidates reviewed bindings.
  public let sourceRevision: String
  /// A host-generated digest covering the executable configuration and policy.
  /// It must not contain an environment override value or credential.
  public let configurationDigest: String
  public let requiredScopes: Set<AIAgentPermissionScope>
  public let executionPolicy: AIAgentToolExecutionPolicy
  public let connectionTimeoutMilliseconds: UInt64
  public let commandTimeoutMilliseconds: UInt64
  public let maximumInputByteCount: Int
  public let maximumOutputByteCount: Int
  public let maximumRawMessageByteCount: Int
  public let maximumContentBlockCount: Int
  public let maximumToolDescriptionByteCount: Int
  public let maximumToolPageCount: Int
  public let maximumToolCount: Int
  private let executableIdentity: PublishingMCPFilesystemIdentity
  private let workingDirectoryIdentity: PublishingMCPFilesystemIdentity?
  private let launchArtifactIdentities: [PublishingMCPFilesystemIdentity]
  fileprivate let verifiedAuthorityDigest: String

  public init(
    sourceID: String,
    executableURL: URL,
    arguments: [String],
    workingDirectoryURL: URL? = nil,
    pinnedLaunchArtifactURLs: [URL] = [],
    environmentOverrides: [String: String] = [:],
    authorityKey: PublishingMCPAuthorityKey? = nil,
    sourceRevision: String,
    configurationDigest: String,
    requiredScopes: Set<AIAgentPermissionScope>,
    executionPolicy: AIAgentToolExecutionPolicy = .requiresConfirmation,
    connectionTimeoutMilliseconds: UInt64 = 3_000,
    commandTimeoutMilliseconds: UInt64 = 15_000,
    maximumInputByteCount: Int = 16 * 1_024,
    maximumOutputByteCount: Int = 64 * 1_024,
    maximumRawMessageByteCount: Int = 256 * 1_024,
    maximumContentBlockCount: Int = 128,
    maximumToolDescriptionByteCount: Int = 4 * 1_024,
    maximumToolPageCount: Int = 16,
    maximumToolCount: Int = 128
  ) throws {
    let normalizedSourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRevision = sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDigest = configurationDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedExecutableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedWorkingDirectoryURL =
      workingDirectoryURL?.resolvingSymlinksInPath().standardizedFileURL
    let executableIdentity = PublishingMCPFilesystemIdentity.capture(
      resolvedExecutableURL,
      expectingDirectory: false
    )
    let workingDirectoryIdentity = resolvedWorkingDirectoryURL.flatMap {
      PublishingMCPFilesystemIdentity.capture($0, expectingDirectory: true)
    }
    let argumentBaseURL =
      resolvedWorkingDirectoryURL
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let automaticLaunchArtifactURLs = arguments.compactMap { argument -> URL? in
      guard !argument.isEmpty, !argument.hasPrefix("-") else { return nil }
      let candidate = URL(fileURLWithPath: argument, relativeTo: argumentBaseURL)
        .resolvingSymlinksInPath().standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        return nil
      }
      return candidate
    }
    let resolvedLaunchArtifactURLs = Array(
      Dictionary(
        (pinnedLaunchArtifactURLs + automaticLaunchArtifactURLs).map {
          let resolved = $0.resolvingSymlinksInPath().standardizedFileURL
          return (resolved.path, resolved)
        },
        uniquingKeysWith: { first, _ in first }
      ).values
    ).sorted { $0.path < $1.path }
    let launchArtifactIdentities = resolvedLaunchArtifactURLs.compactMap {
      PublishingMCPFilesystemIdentity.capture($0, expectingDirectory: false)
    }
    let argumentByteCount = arguments.reduce(0) {
      $0.saturatingAdd($1.utf8.count)
    }
    let environmentByteCount = environmentOverrides.reduce(0) {
      $0.saturatingAdd($1.key.utf8.count).saturatingAdd($1.value.utf8.count)
    }
    guard Self.isValidSourceID(normalizedSourceID),
      executableURL.isFileURL,
      !resolvedExecutableURL.path.isEmpty,
      FileManager.default.isExecutableFile(atPath: resolvedExecutableURL.path),
      executableIdentity != nil,
      workingDirectoryURL == nil || workingDirectoryURL?.isFileURL == true,
      workingDirectoryURL == nil || workingDirectoryIdentity != nil,
      pinnedLaunchArtifactURLs.allSatisfy(\.isFileURL),
      resolvedLaunchArtifactURLs.count <= 64,
      launchArtifactIdentities.count == resolvedLaunchArtifactURLs.count,
      Self.isValidRevisionComponent(normalizedRevision),
      Self.isValidRevisionComponent(normalizedDigest),
      !requiredScopes.isEmpty,
      connectionTimeoutMilliseconds > 0,
      connectionTimeoutMilliseconds <= 300_000,
      commandTimeoutMilliseconds > 0,
      commandTimeoutMilliseconds <= 300_000,
      maximumInputByteCount > 0,
      maximumOutputByteCount > 0,
      maximumRawMessageByteCount >= maximumInputByteCount,
      maximumRawMessageByteCount >= maximumOutputByteCount,
      maximumRawMessageByteCount <= 4 * 1_024 * 1_024,
      maximumContentBlockCount > 0,
      maximumContentBlockCount <= 1_024,
      maximumToolDescriptionByteCount > 0,
      maximumToolDescriptionByteCount <= 64 * 1_024,
      maximumToolPageCount > 0,
      maximumToolCount > 0,
      arguments.count <= 128,
      argumentByteCount <= 64 * 1_024,
      arguments.allSatisfy({ !$0.contains("\0") }),
      environmentOverrides.count <= 64,
      environmentByteCount <= 256 * 1_024,
      environmentOverrides.isEmpty || authorityKey != nil,
      environmentOverrides.allSatisfy({
        Self.isValidEnvironmentName($0.key) && !Self.isBlockedEnvironmentOverride($0.key)
          && !$0.value.contains("\0")
      })
    else {
      throw PublishingMCPClientError.invalidConfiguration
    }

    self.sourceID = normalizedSourceID
    self.executableURL = resolvedExecutableURL
    self.arguments = arguments
    self.workingDirectoryURL = resolvedWorkingDirectoryURL
    self.pinnedLaunchArtifactURLs = resolvedLaunchArtifactURLs
    self.environmentOverrides = environmentOverrides
    self.sourceRevision = normalizedRevision
    self.configurationDigest = normalizedDigest
    self.requiredScopes = requiredScopes
    self.executionPolicy = executionPolicy
    self.connectionTimeoutMilliseconds = connectionTimeoutMilliseconds
    self.commandTimeoutMilliseconds = commandTimeoutMilliseconds
    self.maximumInputByteCount = maximumInputByteCount
    self.maximumOutputByteCount = maximumOutputByteCount
    self.maximumRawMessageByteCount = maximumRawMessageByteCount
    self.maximumContentBlockCount = maximumContentBlockCount
    self.maximumToolDescriptionByteCount = maximumToolDescriptionByteCount
    self.maximumToolPageCount = maximumToolPageCount
    self.maximumToolCount = maximumToolCount
    self.executableIdentity = executableIdentity!
    self.workingDirectoryIdentity = workingDirectoryIdentity
    self.launchArtifactIdentities = launchArtifactIdentities
    self.verifiedAuthorityDigest = Self.authorityDigest(
      sourceID: normalizedSourceID,
      executableIdentity: executableIdentity!,
      arguments: arguments,
      workingDirectoryIdentity: workingDirectoryIdentity,
      launchArtifactIdentities: launchArtifactIdentities,
      environmentOverrides: environmentOverrides,
      authorityKey: authorityKey,
      sourceRevision: normalizedRevision,
      configurationDigest: normalizedDigest,
      requiredScopes: requiredScopes,
      executionPolicy: executionPolicy,
      connectionTimeoutMilliseconds: connectionTimeoutMilliseconds,
      commandTimeoutMilliseconds: commandTimeoutMilliseconds,
      maximumInputByteCount: maximumInputByteCount,
      maximumOutputByteCount: maximumOutputByteCount,
      maximumRawMessageByteCount: maximumRawMessageByteCount,
      maximumContentBlockCount: maximumContentBlockCount,
      maximumToolDescriptionByteCount: maximumToolDescriptionByteCount,
      maximumToolPageCount: maximumToolPageCount,
      maximumToolCount: maximumToolCount
    )
  }

  private static func isValidSourceID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 96
      && value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 90)
          || (scalar.value >= 97 && scalar.value <= 122)
          || scalar == "-" || scalar == "_"
      }
  }

  private static func isValidEnvironmentName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      (scalar.value >= 48 && scalar.value <= 57)
        || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
        || scalar == "_"
    }
  }

  private static func isValidRevisionComponent(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 90)
          || (scalar.value >= 97 && scalar.value <= 122)
          || scalar == "-" || scalar == "_" || scalar == "."
      }
  }

  private static func isBlockedEnvironmentOverride(_ key: String) -> Bool {
    key == "PATH" || key == "HOME" || key == "TMPDIR" || key == "NODE_OPTIONS"
      || key == "PYTHONHOME" || key == "PYTHONPATH" || key == "PYTHONSTARTUP"
      || key == "RUBYOPT" || key == "BASH_ENV" || key == "ENV" || key == "SHELLOPTS"
      || key.hasPrefix("DYLD_") || key.hasPrefix("LD_")
  }

  private static func authorityDigest(
    sourceID: String,
    executableIdentity: PublishingMCPFilesystemIdentity,
    arguments: [String],
    workingDirectoryIdentity: PublishingMCPFilesystemIdentity?,
    launchArtifactIdentities: [PublishingMCPFilesystemIdentity],
    environmentOverrides: [String: String],
    authorityKey: PublishingMCPAuthorityKey?,
    sourceRevision: String,
    configurationDigest: String,
    requiredScopes: Set<AIAgentPermissionScope>,
    executionPolicy: AIAgentToolExecutionPolicy,
    connectionTimeoutMilliseconds: UInt64,
    commandTimeoutMilliseconds: UInt64,
    maximumInputByteCount: Int,
    maximumOutputByteCount: Int,
    maximumRawMessageByteCount: Int,
    maximumContentBlockCount: Int,
    maximumToolDescriptionByteCount: Int,
    maximumToolPageCount: Int,
    maximumToolCount: Int
  ) -> String {
    var material = ""
    func append(_ value: String?) {
      guard let value else {
        material += "-1:"
        return
      }
      material += "\(value.utf8.count):\(value)"
    }
    func appendIdentity(_ identity: PublishingMCPFilesystemIdentity?) {
      guard let identity else {
        append(nil)
        return
      }
      append(identity.resolvedPath)
      append(String(identity.deviceID))
      append(String(identity.fileID))
      append(identity.isDirectory ? "directory" : "file")
      append(identity.byteCount.map(String.init))
      append(identity.modificationDate.map { String($0.timeIntervalSince1970.bitPattern) })
      append(identity.contentSHA256)
    }

    append(sourceID)
    appendIdentity(executableIdentity)
    for argument in arguments {
      append(argument)
    }
    appendIdentity(workingDirectoryIdentity)
    for identity in launchArtifactIdentities.sorted(by: {
      $0.resolvedPath < $1.resolvedPath
    }) {
      appendIdentity(identity)
    }
    for (key, value) in environmentOverrides.sorted(by: { $0.key < $1.key }) {
      append(key)
      append(value)
    }
    append(sourceRevision)
    append(configurationDigest)
    append(requiredScopes.map(\.rawValue).sorted().joined(separator: ","))
    append(executionPolicy.rawValue)
    append(String(connectionTimeoutMilliseconds))
    append(String(commandTimeoutMilliseconds))
    append(String(maximumInputByteCount))
    append(String(maximumOutputByteCount))
    append(String(maximumRawMessageByteCount))
    append(String(maximumContentBlockCount))
    append(String(maximumToolDescriptionByteCount))
    append(String(maximumToolPageCount))
    append(String(maximumToolCount))
    guard let authorityKey else {
      return Self.sha256(material)
    }
    let authenticationCode = HMAC<SHA256>.authenticationCode(
      for: Data(material.utf8),
      using: SymmetricKey(data: authorityKey.rawRepresentation)
    )
    return authenticationCode.map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate func hasCurrentFilesystemIdentity() -> Bool {
    guard
      PublishingMCPFilesystemIdentity.capture(executableURL, expectingDirectory: false)
        == executableIdentity
    else {
      return false
    }
    if let workingDirectoryURL {
      guard
        PublishingMCPFilesystemIdentity.capture(
          workingDirectoryURL,
          expectingDirectory: true
        ) == workingDirectoryIdentity
      else {
        return false
      }
    } else if workingDirectoryIdentity != nil {
      return false
    }
    return zip(pinnedLaunchArtifactURLs, launchArtifactIdentities).allSatisfy { url, identity in
      PublishingMCPFilesystemIdentity.capture(url, expectingDirectory: false) == identity
    }
  }
}

public enum PublishingMCPClientError: Error, Equatable, Sendable {
  case invalidConfiguration
  case connectionFailed
  case requestTimedOut
  case processExited
  case discoveryLimitExceeded
  case invalidRemoteTool
  case unsupportedToolContent
  case outputLimitExceeded
  case invocationMismatch
}

/// A checked, SDK-independent representation of one remote MCP tool.
public struct PublishingMCPDiscoveredTool: Hashable, Sendable {
  public let remoteName: String
  public let description: String?
  public let inputSchema: AIStructuredOutputJSONValue

  public init(remoteName: String, description: String?, inputSchema: AIStructuredOutputJSONValue) {
    self.remoteName = remoteName
    self.description = description
    self.inputSchema = inputSchema
  }
}

enum PublishingMCPProcessLauncher {
  static func configureSpawnAttributes(_ attributes: inout posix_spawnattr_t?) -> Int32 {
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    let flagsResult = posix_spawnattr_setflags(&attributes, flags)
    guard flagsResult == 0 else { return flagsResult }
    return posix_spawnattr_setpgroup(&attributes, 0)
  }

  fileprivate static func launch(
    executableURL: URL,
    arguments: [String],
    workingDirectoryURL: URL?,
    environment: [String: String],
    standardInput: Int32,
    standardOutput: Int32,
    standardError: Int32
  ) throws -> PublishingMCPSpawnedProcess {
    let argumentVector = try PublishingMCPCStringArray(
      [executableURL.path] + arguments
    )
    let environmentVector = try PublishingMCPCStringArray(
      environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    )

    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw PublishingMCPClientError.connectionFailed
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    for (source, destination) in [
      (standardInput, STDIN_FILENO),
      (standardOutput, STDOUT_FILENO),
      (standardError, STDERR_FILENO),
    ] {
      guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
        throw PublishingMCPClientError.connectionFailed
      }
      if source != destination,
        posix_spawn_file_actions_addclose(&fileActions, source) != 0
      {
        throw PublishingMCPClientError.connectionFailed
      }
    }

    if let workingDirectoryURL {
      let changeDirectoryResult = workingDirectoryURL.path.withCString { path in
        if #available(macOS 26.0, *) {
          posix_spawn_file_actions_addchdir(&fileActions, path)
        } else {
          posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
      }
      guard changeDirectoryResult == 0 else {
        throw PublishingMCPClientError.connectionFailed
      }
    }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw PublishingMCPClientError.connectionFailed
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard configureSpawnAttributes(&attributes) == 0 else {
      throw PublishingMCPClientError.connectionFailed
    }

    var processIdentifier: pid_t = 0
    let spawnResult = executableURL.path.withCString { executablePath in
      posix_spawn(
        &processIdentifier,
        executablePath,
        &fileActions,
        &attributes,
        argumentVector.pointer,
        environmentVector.pointer
      )
    }
    guard spawnResult == 0, processIdentifier > 0 else {
      throw PublishingMCPClientError.connectionFailed
    }
    // POSIX_SPAWN_SETPGROUP with pgroup 0 is the atomic creation contract.
    // A post-spawn getpgid check is inherently racy: a leader may already be
    // an unreaped zombie while ordinary descendants remain in its group.
    return PublishingMCPSpawnedProcess(processIdentifier: processIdentifier)
  }
}

private final class PublishingMCPCStringArray {
  let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let strings: [UnsafeMutablePointer<CChar>]

  init(_ values: [String]) throws {
    var strings: [UnsafeMutablePointer<CChar>] = []
    strings.reserveCapacity(values.count)
    for value in values {
      guard let string = strdup(value) else {
        for allocatedString in strings {
          free(allocatedString)
        }
        throw PublishingMCPClientError.connectionFailed
      }
      strings.append(string)
    }
    let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
      capacity: strings.count + 1
    )
    pointer.initialize(repeating: nil, count: strings.count + 1)
    for (index, string) in strings.enumerated() {
      pointer[index] = string
    }
    self.pointer = pointer
    self.strings = strings
  }

  deinit {
    for string in strings {
      free(string)
    }
    pointer.deinitialize(count: strings.count + 1)
    pointer.deallocate()
  }
}

private final class PublishingMCPSpawnedProcess {
  let processIdentifier: pid_t
  let processGroupIdentifier: pid_t
  private let terminator: PublishingMCPProcessTerminator

  init(processIdentifier: pid_t) {
    self.processIdentifier = processIdentifier
    self.processGroupIdentifier = processIdentifier
    self.terminator = PublishingMCPProcessTerminator(
      processIdentifier: processIdentifier,
      processGroupIdentifier: processIdentifier
    )
    // WNOWAIT observes even an already-exited leader without reaping it. The
    // terminator retains the sole waitpid ownership until the group has first
    // received its final signal, preventing PID/PGID reuse during cleanup.
    DispatchQueue.global(qos: .utility).async { [terminator] in
      var information = siginfo_t()
      while Darwin.waitid(
        P_PID,
        id_t(processIdentifier),
        &information,
        WEXITED | WNOWAIT
      ) == -1, errno == EINTR {}
      terminator.terminateThenKillAfterGracePeriod()
    }
  }

  deinit {
    terminator.terminateThenKillAfterGracePeriod()
  }

  var isRunning: Bool {
    Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
  }

  func terminateThenKillAfterGracePeriod() {
    terminator.terminateThenKillAfterGracePeriod()
  }
}

protocol PublishingMCPClientSession: AnyObject, Sendable {
  func connect() async throws
  func listTools() async throws -> [PublishingMCPDiscoveredTool]
  func call(
    remoteToolName: String,
    argumentsJSON: String
  ) async throws -> WorkbenchAIAgentToolResult
  func close() async
}

typealias PublishingMCPClientSessionFactory =
  @Sendable (PublishingMCPSourceConfiguration) async -> any PublishingMCPClientSession

/// Owns the local Process, pipes, MCP transport, and SDK client for a single
/// connection. It is deliberately internal so MCP session concepts do not
/// escape into the Agent core.
private actor PublishingMCPStdioSession: PublishingMCPClientSession {
  private let configuration: PublishingMCPSourceConfiguration
  private var process: PublishingMCPSpawnedProcess?
  private var client: Client?
  private var transport: StdioTransport?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stdoutRelay: PublishingMCPFrameRelay?
  private var stderrDrainer: PublishingMCPStderrDrainer?

  init(configuration: PublishingMCPSourceConfiguration) {
    self.configuration = configuration
  }

  func connect() async throws {
    guard client == nil else { return }
    guard configuration.hasCurrentFilesystemIdentity(),
      FileManager.default.isExecutableFile(atPath: configuration.executableURL.path)
    else {
      throw PublishingMCPClientError.connectionFailed
    }

    let stdinPipe = Pipe()
    let rawStdoutPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutRelay = PublishingMCPFrameRelay(
      input: rawStdoutPipe.fileHandleForReading,
      output: stdoutPipe.fileHandleForWriting,
      maximumFrameByteCount: configuration.maximumRawMessageByteCount
    )

    let stderrDrainer = PublishingMCPStderrDrainer(
      handle: stderrPipe.fileHandleForReading,
      maximumDiscardedBytes: 64 * 1_024
    )
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stdoutRelay = stdoutRelay
    self.stderrDrainer = stderrDrainer
    stdoutRelay.start()
    stderrDrainer.start()

    do {
      let process = try PublishingMCPProcessLauncher.launch(
        executableURL: configuration.executableURL,
        arguments: configuration.arguments,
        workingDirectoryURL: configuration.workingDirectoryURL,
        environment: Self.launchEnvironment(overrides: configuration.environmentOverrides),
        standardInput: stdinPipe.fileHandleForReading.fileDescriptor,
        standardOutput: rawStdoutPipe.fileHandleForWriting.fileDescriptor,
        standardError: stderrPipe.fileHandleForWriting.fileDescriptor
      )
      self.process = process
      stdinPipe.fileHandleForReading.closeFile()
      rawStdoutPipe.fileHandleForWriting.closeFile()
      stderrPipe.fileHandleForWriting.closeFile()
      let transport = StdioTransport(
        input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
        output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
      )
      let client = Client(
        name: "PersonalSitePublisherMac",
        version: "1",
        capabilities: .init(),
        configuration: .strict
      )
      self.transport = transport
      self.client = client
      _ = try await withTimeout(milliseconds: configuration.connectionTimeoutMilliseconds) {
        try await client.connect(transport: transport)
      }
    } catch {
      let mappedError = mappedTransportError(error)
      await close()
      throw mappedError is PublishingMCPClientError
        ? mappedError : PublishingMCPClientError.connectionFailed
    }
  }

  func listTools() async throws -> [PublishingMCPDiscoveredTool] {
    try assertRunning()
    guard let client else { throw PublishingMCPClientError.connectionFailed }
    var cursor: String?
    var pages = 0
    var tools: [PublishingMCPDiscoveredTool] = []
    var remoteNames = Set<String>()

    repeat {
      pages += 1
      guard pages <= configuration.maximumToolPageCount else {
        throw PublishingMCPClientError.discoveryLimitExceeded
      }
      let pageCursor = cursor
      let page: (tools: [Tool], nextCursor: String?)
      do {
        page = try await withTimeout(milliseconds: configuration.connectionTimeoutMilliseconds) {
          try await client.listTools(cursor: pageCursor)
        }
      } catch {
        throw mappedTransportError(error)
      }
      for tool in page.tools {
        let checked = try Self.checkedTool(tool, configuration: configuration)
        guard remoteNames.insert(checked.remoteName).inserted else {
          throw PublishingMCPClientError.invalidRemoteTool
        }
        tools.append(checked)
        guard tools.count <= configuration.maximumToolCount else {
          throw PublishingMCPClientError.discoveryLimitExceeded
        }
      }
      cursor = page.nextCursor
    } while cursor != nil

    return tools.sorted { $0.remoteName < $1.remoteName }
  }

  func call(remoteToolName: String, argumentsJSON: String) async throws
    -> WorkbenchAIAgentToolResult
  {
    try assertRunning()
    guard let client else { throw PublishingMCPClientError.connectionFailed }
    guard argumentsJSON.utf8.count <= configuration.maximumInputByteCount,
      let arguments = Self.decodeArguments(argumentsJSON)
    else {
      throw PublishingMCPClientError.invocationMismatch
    }

    let response: CallTool.Result
    do {
      response = try await withTimeout(milliseconds: configuration.commandTimeoutMilliseconds) {
        let request: RequestContext<CallTool.Result> = try await client.callTool(
          name: remoteToolName,
          arguments: arguments
        )
        return try await request.value
      }
    } catch {
      throw mappedTransportError(error)
    }
    guard response.structuredContent == nil else {
      return WorkbenchAIAgentToolResult(
        content: "External MCP tool returned unsupported structured content.",
        isError: true
      )
    }
    guard response.content.count <= configuration.maximumContentBlockCount else {
      return WorkbenchAIAgentToolResult(
        content: "External MCP tool returned too many content blocks.",
        isError: true
      )
    }
    var textBlocks: [String] = []
    var byteCount = 0
    for content in response.content {
      guard case .text(let text, _, _) = content else {
        return WorkbenchAIAgentToolResult(
          content: "External MCP tool returned unsupported content.",
          isError: true
        )
      }
      if !textBlocks.isEmpty {
        byteCount = byteCount.saturatingAdd(1)
      }
      byteCount = byteCount.saturatingAdd(text.utf8.count)
      guard byteCount <= configuration.maximumOutputByteCount else {
        return WorkbenchAIAgentToolResult(
          content: "External MCP tool returned more content than allowed.",
          isError: true
        )
      }
      textBlocks.append(text)
    }
    let content = textBlocks.joined(separator: "\n")
    return WorkbenchAIAgentToolResult(content: content, isError: response.isError == true)
  }

  func close() async {
    if let client {
      await client.disconnect()
    } else if let transport {
      await transport.disconnect()
    }
    stderrDrainer?.stop()
    stdoutRelay?.stop()
    stdinPipe?.fileHandleForWriting.closeFile()
    stdoutPipe?.fileHandleForReading.closeFile()
    terminateProcessIfNeeded()
    client = nil
    transport = nil
    process = nil
    stdinPipe = nil
    stdoutPipe = nil
    stdoutRelay = nil
    stderrDrainer = nil
  }

  private func assertRunning() throws {
    guard process?.isRunning == true else { throw PublishingMCPClientError.processExited }
  }

  private func withTimeout<T: Sendable>(
    milliseconds: UInt64,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        throw PublishingMCPClientError.requestTimedOut
      }
      defer { group.cancelAll() }
      do {
        guard let value = try await group.next() else {
          throw PublishingMCPClientError.connectionFailed
        }
        return value
      } catch let error as PublishingMCPClientError where error == .requestTimedOut {
        // Disconnect after the timer wins. This unblocks the pending SDK
        // continuation before the task group leaves scope, while preserving a
        // deterministic timeout error for callers.
        await forceCloseForTimeout()
        throw error
      } catch is CancellationError {
        await forceCloseForTimeout()
        throw CancellationError()
      } catch {
        throw error
      }
    }
  }

  private func forceCloseForTimeout() async {
    if let client {
      await client.disconnect()
    } else if let transport {
      await transport.disconnect()
    }
    stderrDrainer?.stop()
    stdoutRelay?.stop()
    stdinPipe?.fileHandleForWriting.closeFile()
    stdoutPipe?.fileHandleForReading.closeFile()
    terminateProcessIfNeeded()
  }

  private func terminateProcessIfNeeded() {
    process?.terminateThenKillAfterGracePeriod()
  }

  private func mappedTransportError(_ error: Error) -> Error {
    stdoutRelay?.didExceedFrameLimit == true
      ? PublishingMCPClientError.outputLimitExceeded : error
  }

  private static func launchEnvironment(overrides: [String: String]) -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    let permittedInheritedKeys: Set<String> = [
      "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "TMPDIR", "USER",
    ]
    var environment = inherited.filter { permittedInheritedKeys.contains($0.key) }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["NO_COLOR"] = "1"
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment
  }

  private static func checkedTool(
    _ tool: Tool,
    configuration: PublishingMCPSourceConfiguration
  ) throws -> PublishingMCPDiscoveredTool {
    guard isValidRemoteToolName(tool.name) else { throw PublishingMCPClientError.invalidRemoteTool }
    let schemaData = try JSONEncoder().encode(tool.inputSchema)
    guard schemaData.count <= configuration.maximumInputByteCount,
      (tool.description?.utf8.count ?? 0) <= configuration.maximumToolDescriptionByteCount,
      let schema = try? JSONDecoder().decode(AIStructuredOutputJSONValue.self, from: schemaData),
      case .object(let object) = schema,
      case .string(let type)? = object["type"], type == "object",
      PublishingMCPJSONSchemaValidator.isSupportedRootSchema(schema)
    else {
      throw PublishingMCPClientError.invalidRemoteTool
    }
    return PublishingMCPDiscoveredTool(
      remoteName: tool.name,
      description: tool.description,
      inputSchema: schema
    )
  }

  private static func decodeArguments(_ json: String) -> [String: Value]? {
    guard let data = json.data(using: .utf8),
      let value = try? JSONDecoder().decode(Value.self, from: data),
      case .object(let object) = value
    else { return nil }
    return object
  }

  private static func isValidRemoteToolName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 128
      && name.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 90)
          || (scalar.value >= 97 && scalar.value <= 122)
          || scalar == "-" || scalar == "_" || scalar == "."
      }
  }
}

private final class PublishingMCPStderrDrainer: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()
  private var discardedByteCount = 0
  private var isStopped = false
  private let maximumDiscardedBytes: Int

  init(handle: FileHandle, maximumDiscardedBytes: Int) {
    self.handle = handle
    self.maximumDiscardedBytes = maximumDiscardedBytes
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    handle.readabilityHandler = { [weak self] _ in
      self?.discardReadableData()
    }
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    isStopped = true
    handle.readabilityHandler = nil
    handle.closeFile()
  }

  private func discardReadableData() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    let data = handle.availableData
    guard !data.isEmpty else { return }
    discardedByteCount = min(
      maximumDiscardedBytes,
      discardedByteCount.saturatingAdd(data.count)
    )
  }
}

private final class PublishingMCPProcessTerminator: @unchecked Sendable {
  private let processIdentifier: pid_t
  private let processGroupIdentifier: pid_t
  private let lock = NSLock()
  private var terminationRequested = false

  init(processIdentifier: pid_t, processGroupIdentifier: pid_t) {
    self.processIdentifier = processIdentifier
    self.processGroupIdentifier = processGroupIdentifier
  }

  func terminateThenKillAfterGracePeriod() {
    lock.lock()
    guard !terminationRequested else {
      lock.unlock()
      return
    }
    terminationRequested = true
    signal(SIGTERM)
    lock.unlock()
    Task { [self] in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      killIfStillRunning()
    }
  }

  private func killIfStillRunning() {
    lock.lock()
    defer { lock.unlock() }
    signal(SIGKILL)
    _ = Darwin.kill(processIdentifier, SIGKILL)
    reapLeader()
  }

  private func signal(_ value: Int32) {
    _ = Darwin.kill(-processGroupIdentifier, value)
  }

  private func reapLeader() {
    var status: Int32 = 0
    while true {
      let result = Darwin.waitpid(processIdentifier, &status, 0)
      if result == processIdentifier || (result == -1 && errno == ECHILD) {
        return
      }
      if result == -1, errno == EINTR {
        continue
      }
      return
    }
  }
}

extension Int {
  fileprivate func saturatingAdd(_ other: Int) -> Int {
    let (value, overflow) = addingReportingOverflow(other)
    return overflow ? Int.max : value
  }
}

/// Public façade around the isolated stdio lifecycle. It intentionally exports
/// checked discovery while keeping raw calls and SDK transport/session types
/// behind the module boundary.
public actor PublishingMCPClient {
  public nonisolated let configuration: PublishingMCPSourceConfiguration
  private let sessionFactory: PublishingMCPClientSessionFactory
  private var session: (any PublishingMCPClientSession)?
  private var connectionTask: Task<any PublishingMCPClientSession, Error>?
  private var connectionGeneration: UInt64 = 0

  public init(configuration: PublishingMCPSourceConfiguration) {
    self.configuration = configuration
    self.sessionFactory = { configuration in
      PublishingMCPStdioSession(configuration: configuration)
    }
  }

  init(
    configuration: PublishingMCPSourceConfiguration,
    sessionFactory: @escaping PublishingMCPClientSessionFactory
  ) {
    self.configuration = configuration
    self.sessionFactory = sessionFactory
  }

  deinit {
    let session = session
    let connectionTask = connectionTask
    connectionTask?.cancel()
    Task {
      if let connectionTask, let pendingSession = try? await connectionTask.value {
        await pendingSession.close()
      }
      await session?.close()
    }
  }

  public func discoverTools() async throws -> [PublishingMCPDiscoveredTool] {
    try await ensureConnected()
    guard let activeSession = session else { throw PublishingMCPClientError.connectionFailed }
    do {
      return try await activeSession.listTools()
    } catch {
      await invalidateIfCurrent(activeSession)
      throw error
    }
  }

  func call(
    remoteToolName: String,
    argumentsJSON: String
  ) async throws -> WorkbenchAIAgentToolResult {
    try await ensureConnected()
    guard let activeSession = session else { throw PublishingMCPClientError.connectionFailed }
    do {
      return try await activeSession.call(
        remoteToolName: remoteToolName,
        argumentsJSON: argumentsJSON
      )
    } catch {
      await invalidateIfCurrent(activeSession)
      throw error
    }
  }

  public func disconnect() async {
    connectionGeneration &+= 1
    let connectionTask = connectionTask
    let activeSession = session
    self.connectionTask = nil
    self.session = nil
    connectionTask?.cancel()
    if let connectionTask, let pendingSession = try? await connectionTask.value {
      await pendingSession.close()
    }
    await activeSession?.close()
  }

  private func ensureConnected() async throws {
    guard session == nil else { return }
    let generation = connectionGeneration
    let task: Task<any PublishingMCPClientSession, Error>
    if let connectionTask {
      task = connectionTask
    } else {
      let configuration = configuration
      let sessionFactory = sessionFactory
      task = Task {
        try Task.checkCancellation()
        let session = await sessionFactory(configuration)
        do {
          try Task.checkCancellation()
          try await session.connect()
          try Task.checkCancellation()
          return session
        } catch {
          await session.close()
          throw error
        }
      }
      connectionTask = task
    }

    do {
      let connectedSession = try await task.value
      guard generation == connectionGeneration else {
        await connectedSession.close()
        throw CancellationError()
      }
      session = connectedSession
      connectionTask = nil
    } catch {
      if generation == connectionGeneration {
        connectionTask = nil
      }
      throw error
    }
  }

  private func invalidateIfCurrent(
    _ failedSession: any PublishingMCPClientSession
  ) async {
    if let activeSession = session, activeSession === failedSession {
      session = nil
    }
    await failedSession.close()
  }
}

/// Converts one checked MCP discovery snapshot into host-side Agent contracts.
/// A later discovery/configuration must create a new instance, making drift
/// explicit instead of silently updating reviewed calls.
public struct PublishingMCPToolRegistry: WorkbenchAIAgentToolRegistry {
  public let catalog: AIAgentToolCatalogSnapshot
  public let configuration: PublishingMCPSourceConfiguration
  private let toolsByModelName: [String: PublishingMCPDiscoveredTool]
  private let toolsByRemoteName: [String: PublishingMCPDiscoveredTool]

  public init(
    configuration: PublishingMCPSourceConfiguration,
    tools: [PublishingMCPDiscoveredTool]
  ) throws {
    var byModelName: [String: PublishingMCPDiscoveredTool] = [:]
    var byRemoteName: [String: PublishingMCPDiscoveredTool] = [:]
    var descriptors: [AIAgentToolDescriptor] = []
    for tool in tools.sorted(by: { $0.remoteName < $1.remoteName }) {
      try Self.validate(tool: tool, configuration: configuration)
      let modelName = Self.modelVisibleName(
        sourceID: configuration.sourceID,
        remoteToolName: tool.remoteName
      )
      guard byModelName[modelName] == nil,
        byRemoteName.updateValue(tool, forKey: tool.remoteName) == nil
      else {
        throw PublishingMCPClientError.invalidRemoteTool
      }
      byModelName[modelName] = tool
      descriptors.append(
        AIAgentToolDescriptor(
          id: Self.toolID(sourceID: configuration.sourceID, remoteToolName: tool.remoteName),
          definition: AIToolDefinition(
            function: AIToolFunctionDefinition(
              name: modelName,
              description: tool.description,
              parameters: tool.inputSchema,
              strict: nil
            )
          ),
          requiredScopes: configuration.requiredScopes,
          executionPolicy: configuration.executionPolicy
        )
      )
    }
    self.configuration = configuration
    self.toolsByModelName = byModelName
    self.toolsByRemoteName = byRemoteName
    self.catalog = try AIAgentToolCatalogSnapshot(
      revision:
        "mcp-v2/\(configuration.sourceID)/\(configuration.sourceRevision)/\(configuration.configurationDigest)/\(configuration.verifiedAuthorityDigest)/\(Self.catalogDigest(descriptors: descriptors))",
      descriptors: descriptors
    )
  }

  public static func toolID(sourceID: String, remoteToolName: String) -> AIAgentToolID {
    AIAgentToolID("mcp/\(sourceID)/\(remoteToolName)")
  }

  public func prepare(
    call: AIToolCall,
    context _: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    guard call.type == "function",
      !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let tool = toolsByModelName[call.function.name],
      let descriptor = catalog.descriptors.first(where: {
        $0.definition.function.name == call.function.name
      }),
      call.function.arguments.utf8.count <= configuration.maximumInputByteCount,
      Self.isJSONObject(call.function.arguments)
    else {
      if toolsByModelName[call.function.name] == nil {
        throw WorkbenchAIAgentToolRegistryError.unknownTool(call.function.name)
      }
      throw WorkbenchAIAgentToolRegistryError.invalidJSON(toolCallID: call.id)
    }

    return WorkbenchAIAgentToolInvocation(
      toolCallID: call.id,
      toolID: descriptor.id,
      modelToolName: descriptor.definition.function.name,
      executionPolicy: descriptor.executionPolicy,
      catalogRevision: catalog.revision,
      externalToolBinding: AIAgentExternalToolBinding(
        sourceID: configuration.sourceID,
        sourceRevision: configuration.sourceRevision,
        remoteToolName: tool.remoteName,
        argumentsJSON: call.function.arguments
      )
    )
  }

  public func revalidate(
    invocation: WorkbenchAIAgentToolInvocation,
    matching call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    let fresh = try prepare(call: call, context: context)
    guard invocation.toolCallID == fresh.toolCallID,
      invocation.toolID == fresh.toolID,
      invocation.modelToolName == fresh.modelToolName,
      invocation.executionPolicy == fresh.executionPolicy,
      invocation.catalogRevision == fresh.catalogRevision,
      invocation.externalToolBinding == fresh.externalToolBinding,
      invocation.automationStep == nil,
      invocation.targetDraftID == nil,
      invocation.targetDraftVersion == nil
    else {
      throw WorkbenchAIAgentToolRegistryError.catalogDrift
    }
    return invocation
  }

  func validatedBinding(
    for invocation: WorkbenchAIAgentToolInvocation
  ) throws -> AIAgentExternalToolBinding {
    guard invocation.catalogRevision == catalog.revision,
      invocation.automationStep == nil,
      invocation.targetDraftID == nil,
      invocation.targetDraftVersion == nil,
      let binding = invocation.externalToolBinding,
      binding.sourceID == configuration.sourceID,
      binding.sourceRevision == configuration.sourceRevision,
      binding.argumentsJSON.utf8.count <= configuration.maximumInputByteCount,
      Self.isJSONObject(binding.argumentsJSON),
      let remoteTool = toolsByRemoteName[binding.remoteToolName],
      let modelTool = toolsByModelName[invocation.modelToolName],
      modelTool.remoteName == remoteTool.remoteName,
      let descriptor = catalog.descriptors.first(where: { $0.id == invocation.toolID }),
      descriptor.definition.function.name == invocation.modelToolName,
      descriptor.executionPolicy == invocation.executionPolicy,
      descriptor.requiredScopes == configuration.requiredScopes,
      invocation.toolID
        == Self.toolID(
          sourceID: configuration.sourceID,
          remoteToolName: remoteTool.remoteName
        )
    else {
      throw PublishingMCPClientError.invocationMismatch
    }
    return binding
  }

  public static func modelVisibleName(sourceID: String, remoteToolName: String) -> String {
    let readable = "mcp_\(normalizedIdentifier(sourceID))_\(normalizedIdentifier(remoteToolName))"
    let suffix = String(stableHash("\(sourceID)\u{1f}\(remoteToolName)"), radix: 16)
    let prefix = String(readable.prefix(64 - suffix.count - 1))
    return "\(prefix)_\(suffix)"
  }

  private static func isJSONObject(_ string: String) -> Bool {
    guard let data = string.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      object is [String: Any]
    else { return false }
    return true
  }

  private static func normalizedIdentifier(_ raw: String) -> String {
    let output = raw.unicodeScalars.map { scalar -> String in
      switch scalar.value {
      case 48...57, 65...90, 97...122:
        return String(scalar).lowercased()
      default:
        return "_"
      }
    }.joined()
    let compact = output.replacingOccurrences(of: "__", with: "_")
    return compact.isEmpty ? "tool" : compact
  }

  private static func stableHash(_ value: String) -> UInt64 {
    value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  private static func catalogDigest(
    descriptors: [AIAgentToolDescriptor]
  ) -> String {
    var material = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func append(_ value: String?) {
      guard let value else {
        material += "-1:"
        return
      }
      material += "\(value.utf8.count):\(value)"
    }
    for descriptor in descriptors.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
      let schema =
        (try? encoder.encode(descriptor.definition.function.parameters))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "invalid"
      append(descriptor.id.rawValue)
      append(descriptor.definition.type)
      append(descriptor.definition.function.name)
      append(descriptor.definition.function.description)
      append(schema)
      append(descriptor.definition.function.strict.map { $0 ? "true" : "false" })
      append(descriptor.requiredScopes.map(\.rawValue).sorted().joined(separator: ","))
      append(descriptor.executionPolicy.rawValue)
    }
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func validate(
    tool: PublishingMCPDiscoveredTool,
    configuration: PublishingMCPSourceConfiguration
  ) throws {
    guard tool.remoteName.utf8.count <= 128,
      !tool.remoteName.isEmpty,
      tool.remoteName.unicodeScalars.allSatisfy({ scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 90)
          || (scalar.value >= 97 && scalar.value <= 122)
          || scalar == "-" || scalar == "_" || scalar == "."
      }),
      let data = try? JSONEncoder().encode(tool.inputSchema),
      data.count <= configuration.maximumInputByteCount,
      (tool.description?.utf8.count ?? 0) <= configuration.maximumToolDescriptionByteCount,
      case .object(let object) = tool.inputSchema,
      case .string(let type)? = object["type"], type == "object",
      PublishingMCPJSONSchemaValidator.isSupportedRootSchema(tool.inputSchema)
    else {
      throw PublishingMCPClientError.invalidRemoteTool
    }
  }
}

/// Executes only a reviewed external binding. It never accepts a model-visible
/// function name as authority and it maps MCP result content conservatively.
public actor PublishingMCPToolExecutor {
  private let client: PublishingMCPClient
  private let registry: PublishingMCPToolRegistry

  public init(
    client: PublishingMCPClient,
    registry: PublishingMCPToolRegistry
  ) throws {
    guard client.configuration == registry.configuration else {
      throw PublishingMCPClientError.invalidConfiguration
    }
    self.client = client
    self.registry = registry
  }

  public func execute(
    _ invocation: WorkbenchAIAgentToolInvocation
  ) async throws -> WorkbenchAIAgentToolResult {
    let binding = try registry.validatedBinding(for: invocation)
    return try await client.call(
      remoteToolName: binding.remoteToolName,
      argumentsJSON: binding.argumentsJSON
    )
  }
}
