import CryptoKit
import Darwin
import Dispatch
import Foundation
import MCP
import PublishingAICore

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
  let verifiedAuthorityDigest: String

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

  func hasCurrentFilesystemIdentity() -> Bool {
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
