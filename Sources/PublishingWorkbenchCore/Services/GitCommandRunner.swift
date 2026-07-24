import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct GitCommandResult: Sendable, Hashable {
  public var terminationStatus: Int32
  public var output: String
  public var didTimeOut: Bool
  public var wasOutputTruncated: Bool

  public init(
    terminationStatus: Int32,
    output: String,
    didTimeOut: Bool = false,
    wasOutputTruncated: Bool = false
  ) {
    self.terminationStatus = terminationStatus
    self.output = output
    self.didTimeOut = didTimeOut
    self.wasOutputTruncated = wasOutputTruncated
  }
}

public struct GitCommandRunner: Sendable {
  public var executableURL: URL
  public var timeout: TimeInterval
  /// Total stdout + stderr retained for diagnostics. Streams are still drained
  /// after this cap so a noisy child process cannot block on full pipes.
  public var maximumOutputBytes: Int

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    timeout: TimeInterval = 15,
    maximumOutputBytes: Int = 1_048_576
  ) {
    self.executableURL = executableURL
    self.timeout = timeout
    self.maximumOutputBytes = max(0, maximumOutputBytes)
  }

  public func run(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil
  ) -> GitCommandResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let outputCollector = BoundedOutputCollector(limit: maximumOutputBytes)
    installDrainHandler(on: outputPipe.fileHandleForReading, collector: outputCollector)
    installDrainHandler(on: errorPipe.fileHandleForReading, collector: outputCollector)

    let inputPipe = Pipe()
    if let inputLines, !inputLines.isEmpty {
      process.standardInput = inputPipe
    }

    let completed = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
      completed.signal()
    }

    do {
      try process.run()
      // Process owns duplicated write descriptors after launch. Closing our
      // copies lets the drainers observe EOF as soon as Git exits.
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      if let inputLines, !inputLines.isEmpty {
        let input = (inputLines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        inputPipe.fileHandleForWriting.write(input)
        inputPipe.fileHandleForWriting.closeFile()
      }
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      return GitCommandResult(terminationStatus: 127, output: error.localizedDescription)
    }

    let didFinish = completed.wait(timeout: .now() + timeout) == .success
    if !didFinish {
      process.terminate()
      if completed.wait(timeout: .now() + 1) == .timedOut {
#if canImport(Darwin)
        Darwin.kill(process.processIdentifier, SIGKILL)
#endif
        _ = completed.wait(timeout: .now() + 1)
      }
    }

    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    if !process.isRunning {
      outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
      outputCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
    }
    outputPipe.fileHandleForReading.closeFile()
    errorPipe.fileHandleForReading.closeFile()

    let collected = outputCollector.result()
    let truncationNotice = collected.didTruncate
      ? "\n[Git output truncated after \(maximumOutputBytes) bytes]"
      : ""
    let mergedOutput = (collected.data + truncationNotice).trimmedForPublishing
    return GitCommandResult(
      terminationStatus: didFinish ? process.terminationStatus : 124,
      output: didFinish
        ? mergedOutput
        : "Git command timed out after \(Int(timeout))s: git \(arguments.map(posixShellQuote).joined(separator: " "))",
      didTimeOut: !didFinish,
      wasOutputTruncated: collected.didTruncate
    )
  }

  /// Runs Git without occupying the caller's executor while the child process
  /// is active. Cancelling the awaiting task terminates the child process.
  public func runAsync(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil
  ) async -> GitCommandResult {
    let operation = GitCommandAsyncOperation(
      executableURL: executableURL,
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes,
      arguments: arguments,
      rootURL: rootURL,
      inputLines: inputLines
    )
    return await withTaskCancellationHandler(operation: {
      await operation.run()
    }, onCancel: {
      operation.cancel()
    })
  }

  private func installDrainHandler(on handle: FileHandle, collector: BoundedOutputCollector) {
    handle.readabilityHandler = { readableHandle in
      let data = readableHandle.availableData
      if data.isEmpty {
        readableHandle.readabilityHandler = nil
      } else {
        collector.append(data)
      }
    }
  }
}

private final class GitCommandAsyncOperation: @unchecked Sendable {
  private let executableURL: URL
  private let timeout: TimeInterval
  private let maximumOutputBytes: Int
  private let arguments: [String]
  private let rootURL: URL
  private let inputLines: [String]?
  private let lock = NSLock()
  private let outputCollector: BoundedOutputCollector
  private var process: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var timeoutTask: Task<Void, Never>?
  private var continuation: CheckedContinuation<GitCommandResult, Never>?
  private var didFinish = false
  private var didTimeOut = false
  private var wasCancelled = false

  init(
    executableURL: URL,
    timeout: TimeInterval,
    maximumOutputBytes: Int,
    arguments: [String],
    rootURL: URL,
    inputLines: [String]?
  ) {
    self.executableURL = executableURL
    self.timeout = timeout
    self.maximumOutputBytes = maximumOutputBytes
    self.arguments = arguments
    self.rootURL = rootURL
    self.inputLines = inputLines
    outputCollector = BoundedOutputCollector(limit: maximumOutputBytes)
  }

  func run() async -> GitCommandResult {
    await withCheckedContinuation { continuation in
      start(continuation)
    }
  }

  func cancel() {
    lock.lock()
    wasCancelled = true
    let process = self.process
    lock.unlock()
    terminate(process)
  }

  private func start(_ continuation: CheckedContinuation<GitCommandResult, Never>) {
    lock.lock()
    self.continuation = continuation
    let shouldCancel = wasCancelled
    lock.unlock()
    if shouldCancel {
      finish(terminationStatus: 130)
      return
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    installDrainHandler(on: outputPipe.fileHandleForReading)
    installDrainHandler(on: errorPipe.fileHandleForReading)

    let inputPipe = Pipe()
    if let inputLines, !inputLines.isEmpty {
      process.standardInput = inputPipe
    }
    process.terminationHandler = { [weak self] process in
      self?.finish(terminationStatus: process.terminationStatus)
    }

    lock.lock()
    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    let cancelAfterSetup = wasCancelled
    lock.unlock()

    do {
      try process.run()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      if let inputLines, !inputLines.isEmpty {
        let input = (inputLines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        inputPipe.fileHandleForWriting.write(input)
        inputPipe.fileHandleForWriting.closeFile()
      }
    } catch {
      finish(terminationStatus: 127, launchError: error.localizedDescription)
      return
    }

    if cancelAfterSetup {
      terminate(process)
      return
    }

    timeoutTask = Task.detached { [weak self] in
      let nanoseconds = UInt64(max(0, self?.timeout ?? 0) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      self?.timeOut()
    }
  }

  private func timeOut() {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didTimeOut = true
    let process = self.process
    lock.unlock()
    terminate(process)
  }

  private func terminate(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    Task.detached {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard process.isRunning else { return }
#if canImport(Darwin)
      Darwin.kill(process.processIdentifier, SIGKILL)
#endif
    }
  }

  private func finish(terminationStatus: Int32, launchError: String? = nil) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    timeoutTask?.cancel()
    timeoutTask = nil
    let continuation = self.continuation
    self.continuation = nil
    let outputPipe = self.outputPipe
    let errorPipe = self.errorPipe
    self.outputPipe = nil
    self.errorPipe = nil
    let timedOut = didTimeOut
    let cancelled = wasCancelled
    lock.unlock()

    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    if let outputPipe {
      outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
      outputPipe.fileHandleForReading.closeFile()
    }
    if let errorPipe {
      outputCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
      errorPipe.fileHandleForReading.closeFile()
    }

    let collected = outputCollector.result()
    let truncationNotice = collected.didTruncate
      ? "\n[Git output truncated after \(maximumOutputBytes) bytes]"
      : ""
    let output: String
    if let launchError {
      output = launchError
    } else if timedOut {
      output = "Git command timed out after \(Int(timeout))s: git \(arguments.map(posixShellQuote).joined(separator: " "))"
    } else if cancelled {
      output = "Git command canceled: git \(arguments.map(posixShellQuote).joined(separator: " "))"
    } else {
      output = (collected.data + truncationNotice).trimmedForPublishing
    }
    continuation?.resume(returning: GitCommandResult(
      terminationStatus: timedOut ? 124 : (cancelled ? 130 : terminationStatus),
      output: output,
      didTimeOut: timedOut,
      wasOutputTruncated: collected.didTruncate
    ))
  }

  private func installDrainHandler(on handle: FileHandle) {
    handle.readabilityHandler = { [weak self] readableHandle in
      let data = readableHandle.availableData
      if data.isEmpty {
        readableHandle.readabilityHandler = nil
      } else {
        self?.outputCollector.append(data)
      }
    }
  }
}

private final class BoundedOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var output = Data()
  private var didTruncate = false

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    let remaining = max(0, limit - output.count)
    if remaining > 0 {
      output.append(data.prefix(remaining))
    }
    if data.count > remaining {
      didTruncate = true
    }
  }

  func result() -> (data: String, didTruncate: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (String(data: output, encoding: .utf8) ?? "", didTruncate)
  }
}
