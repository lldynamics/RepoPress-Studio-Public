import Foundation
import PublishingCoreSupport

#if canImport(Darwin)
  import Darwin
#endif

extension GitCommandRunner {
  @available(
    *, noasync,
    message: "Use runAsync instead in async contexts to avoid blocking cooperative thread pool"
  )
  public func run(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil,
    inputDelimiter: GitCommandInputDelimiter = .newline,
    preserveStandardOutputWhitespace: Bool = false,
    acceptExistingCommitMessage: Bool = false,
    environmentOverrides: [String: String] = [:]
  ) -> GitCommandResult {
    runControlled(
      arguments, rootURL: rootURL, inputLines: inputLines, inputDelimiter: inputDelimiter,
      preserveStandardOutputWhitespace: preserveStandardOutputWhitespace,
      acceptExistingCommitMessage: acceptExistingCommitMessage,
      environmentOverrides: environmentOverrides, configurationOverrides: []
    )
  }

  /// Only explicit commit and hook entrypoints may supply these additional
  /// highest-precedence settings. Ordinary reads retain full isolation.
  func runControlled(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil,
    inputDelimiter: GitCommandInputDelimiter = .newline,
    preserveStandardOutputWhitespace: Bool = false,
    acceptExistingCommitMessage: Bool = false,
    environmentOverrides: [String: String] = [:],
    configurationOverrides: [(String, String)],
    searchPath: String? = nil
  ) -> GitCommandResult {
    GitPipeSignalPolicy.install()
    if let reason = Self.repositoryConfigurationBlockReason(rootURL: rootURL) {
      return Self.blockedConfigurationResult(reason)
    }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-C", rootURL.path] + arguments
    var environment = Self.isolatedGitEnvironment()
    let initialConfigurationCount = Int(environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0
    for (offset, setting) in configurationOverrides.enumerated() {
      let index = initialConfigurationCount + offset
      environment["GIT_CONFIG_KEY_\(index)"] = setting.0
      environment["GIT_CONFIG_VALUE_\(index)"] = setting.1
    }
    environment["GIT_CONFIG_COUNT"] = String(
      initialConfigurationCount + configurationOverrides.count)
    if acceptExistingCommitMessage {
      // `git rebase --continue` may open the existing commit message even
      // though the user already reviewed it. `/usr/bin/true` accepts that
      // frozen message without enabling an arbitrary configured editor.
      environment["GIT_EDITOR"] = "/usr/bin/true"
    }
    // A narrow caller-owned overlay supports isolated Git state such as a
    // temporary index without exposing the host process environment.
    for (key, value) in environmentOverrides where key == "GIT_INDEX_FILE" {
      environment[key] = value
    }
    // Only trusted hook runs pass a search path; Git itself is still launched
    // from `executableURL`, so this affects the programs a hook starts.
    if let searchPath { environment["PATH"] = searchPath }
    process.environment = environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let outputCollector = BoundedOutputCollector(limit: maximumOutputBytes)
    let drainCoordinator = GitPipeDrainCoordinator()
    installDrainHandler(
      on: outputPipe.fileHandleForReading,
      stream: .standardOutput,
      collector: outputCollector,
      coordinator: drainCoordinator
    )
    installDrainHandler(
      on: errorPipe.fileHandleForReading,
      stream: .standardError,
      collector: outputCollector,
      coordinator: drainCoordinator
    )

    let inputData = standardInputData(
      lines: inputLines,
      delimiter: inputDelimiter
    )
    let inputPipe = Pipe()
    if inputData != nil {
      process.standardInput = inputPipe
    }

    let completed = DispatchSemaphore(value: 0)
    let inputWriteCompleted = DispatchSemaphore(value: 0)
    let inputWriteOutcome = GitInputWriteOutcome()
    process.terminationHandler = { _ in
      completed.signal()
    }

    do {
      try process.run()
      let deadline = DispatchTime.now() + timeout
      // Process owns duplicated write descriptors after launch. Closing our
      // copies lets the drainers observe EOF as soon as Git exits.
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      if let inputData {
        inputPipe.fileHandleForReading.closeFile()
        GitStandardInputWriter(data: inputData, handle: inputPipe.fileHandleForWriting)
          .start { errorMessage in
            inputWriteOutcome.record(errorMessage)
            inputWriteCompleted.signal()
          }
      }
      let processFinished = completed.wait(timeout: deadline) == .success
      if !processFinished {
        if process.isRunning { process.terminate() }
        if completed.wait(timeout: .now() + 1) == .timedOut {
          #if canImport(Darwin)
            Darwin.kill(process.processIdentifier, SIGKILL)
          #endif
          _ = completed.wait(timeout: .now() + 1)
        }
      }

      let inputFinished =
        inputData == nil
        || inputWriteCompleted.wait(
          timeout: processFinished ? deadline : .now() + 1
        ) == .success
      if !inputFinished {
        inputWriteOutcome.record("stdin writer did not finish before the command timeout")
      }

      return result(
        process: process,
        outputPipe: outputPipe,
        errorPipe: errorPipe,
        outputCollector: outputCollector,
        drainCoordinator: drainCoordinator,
        arguments: arguments,
        preserveStandardOutputWhitespace: preserveStandardOutputWhitespace,
        didFinish: processFinished && inputFinished,
        inputWriteError: inputWriteOutcome.errorMessage
      )
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      drainCoordinator.stopAndWait()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      if inputData != nil {
        inputPipe.fileHandleForReading.closeFile()
        inputPipe.fileHandleForWriting.closeFile()
      }
      return GitCommandResult(
        terminationStatus: 127,
        standardOutput: "",
        standardError: error.localizedDescription
      )
    }

  }

}
