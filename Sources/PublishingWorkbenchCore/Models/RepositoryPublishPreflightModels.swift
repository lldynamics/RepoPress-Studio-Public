import Foundation

/// A single, non-interactive command used by the repository-wide publication gate.
/// The service only creates commands for an absolute, trusted Zola executable.
public struct RepositoryPublishPreflightCommand: Hashable, Sendable {
  public enum Stage: String, Codable, Hashable, Sendable {
    case check
    case build
  }

  public let stage: Stage
  public let executablePath: String
  public let arguments: [String]
  public let workingDirectoryPath: String
  public let timeout: TimeInterval
  public let maximumOutputBytes: Int

  public init(
    stage: Stage,
    executablePath: String,
    arguments: [String],
    workingDirectoryPath: String,
    timeout: TimeInterval,
    maximumOutputBytes: Int
  ) {
    self.stage = stage
    self.executablePath = executablePath
    self.arguments = arguments
    self.workingDirectoryPath = workingDirectoryPath
    self.timeout = max(1, timeout)
    self.maximumOutputBytes = max(1_024, maximumOutputBytes)
  }
}

/// The bounded result returned by a trusted local command runner.
public struct RepositoryPublishPreflightCommandResult: Hashable, Sendable {
  public enum Termination: String, Codable, Hashable, Sendable {
    case exited
    case timedOut
    case outputTruncated
    case launchFailed
  }

  public let termination: Termination
  public let exitStatus: Int32?
  public let standardOutput: String
  public let standardError: String

  public init(
    termination: Termination,
    exitStatus: Int32? = nil,
    standardOutput: String = "",
    standardError: String = ""
  ) {
    self.termination = termination
    self.exitStatus = exitStatus
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

/// Injectable command boundary. Tests can provide deterministic results without
/// relying on a locally installed Zola binary.
public struct RepositoryPublishPreflightCommandRunner: Sendable {
  public typealias Operation =
    @Sendable (RepositoryPublishPreflightCommand) -> RepositoryPublishPreflightCommandResult

  private let operation: Operation

  public init(operation: @escaping Operation) {
    self.operation = operation
  }

  public func run(_ command: RepositoryPublishPreflightCommand)
    -> RepositoryPublishPreflightCommandResult
  {
    operation(command)
  }
}

public enum RepositoryPublishPreflightSkipReason: String, Codable, Hashable, Sendable {
  case nonZolaProfile
  case zolaConfigurationNotFound
}

public enum RepositoryPublishPreflightFailure: String, Codable, Hashable, Sendable {
  case repositoryUnavailable
  case zolaUnavailable
  case checkFailed
  case buildFailed
  case timedOut
  case outputTruncated
  case launchFailed
  case temporaryOutputUnavailable
}

public enum RepositoryPublishPreflightOutcome: Hashable, Sendable {
  case passed
  case skipped(RepositoryPublishPreflightSkipReason)
  case failed(RepositoryPublishPreflightFailure)
}

/// UI-ready publication-gate evidence. Diagnostic text is bounded and
/// sanitized by the service; it never includes the launch environment.
public struct RepositoryPublishPreflightResult: Hashable, Sendable {
  public let outcome: RepositoryPublishPreflightOutcome
  public let message: String
  public let diagnostics: [String]

  public init(
    outcome: RepositoryPublishPreflightOutcome,
    message: String,
    diagnostics: [String] = []
  ) {
    self.outcome = outcome
    self.message = message
    self.diagnostics = diagnostics
  }

  public var blocksPublication: Bool {
    if case .failed = outcome { return true }
    return false
  }
}
