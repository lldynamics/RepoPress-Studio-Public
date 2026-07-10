import Foundation

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
    let drainGroup = DispatchGroup()
    drain(pipe: outputPipe, into: outputCollector, group: drainGroup)
    drain(pipe: errorPipe, into: outputCollector, group: drainGroup)

    let inputPipe = Pipe()
    if let inputLines, !inputLines.isEmpty {
      process.standardInput = inputPipe
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
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      return GitCommandResult(terminationStatus: 127, output: error.localizedDescription)
    }

    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      completed.signal()
    }

    let didFinish = completed.wait(timeout: .now() + timeout) == .success
    if !didFinish {
      process.terminate()
      _ = completed.wait(timeout: .now() + 1)
    }

    // Process exit closes its pipe ends. Bound the final wait as a child may
    // leave descendants alive while holding an inherited file descriptor.
    if drainGroup.wait(timeout: .now() + 1) == .timedOut {
      outputPipe.fileHandleForReading.closeFile()
      errorPipe.fileHandleForReading.closeFile()
    }

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

  private func drain(pipe: Pipe, into collector: BoundedOutputCollector, group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      while true {
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return }
        collector.append(data)
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
