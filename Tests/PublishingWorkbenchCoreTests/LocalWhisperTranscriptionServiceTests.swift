import Darwin
import Foundation
import PublishingWorkbenchCore
import XCTest

final class LocalWhisperTranscriptionServiceTests: XCTestCase {
  func testSystemRunnerDrainsBothPipesAndBoundsCapturedOutput() async throws {
    let runner = SystemLocalWhisperProcessRunner(
      timeout: 5,
      terminationGracePeriod: 0.1,
      maximumStandardOutputByteCount: 4_096,
      maximumStandardErrorByteCount: 2_048
    )
    let command = """
    i=0
    while [ "$i" -lt 8192 ]; do
      printf '0123456789abcdef'
      printf 'fedcba9876543210' >&2
      i=$((i + 1))
    done
    """

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", command]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.standardOutput.utf8.count, 4_096)
    XCTAssertEqual(result.standardError.utf8.count, 2_048)
    XCTAssertTrue(result.standardOutputWasTruncated)
    XCTAssertTrue(result.standardErrorWasTruncated)
    XCTAssertTrue(result.standardOutput.hasPrefix("0123456789abcdef"))
    XCTAssertTrue(result.standardError.hasSuffix("fedcba9876543210"))
  }

  func testSystemRunnerDoesNotInheritUnapprovedEnvironmentVariables() async throws {
    let variableName = "REPOPRESS_WHISPER_PRIVATE_TEST_VALUE"
    let privateValue = "must-not-reach-child"
    setenv(variableName, privateValue, 1)
    defer { unsetenv(variableName) }
    let runner = SystemLocalWhisperProcessRunner(timeout: 5)

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf '%s' \"${\(variableName)-missing}\""]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.standardOutput, "missing")
    XCTAssertFalse(result.standardOutput.contains(privateValue))
  }

  func testSystemRunnerTimesOutAndTerminatesProcess() async throws {
    let runner = SystemLocalWhisperProcessRunner(
      timeout: 0.1,
      terminationGracePeriod: 0.1
    )
    let startedAt = Date()

    do {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["10"]
      )
      XCTFail("Expected the local process to time out")
    } catch let error as LocalWhisperProcessRunnerError {
      guard case let .timedOut(seconds) = error else {
        return XCTFail("Unexpected runner error: \(error)")
      }
      XCTAssertEqual(seconds, 0.1, accuracy: 0.01)
    }

    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
  }

  func testSystemRunnerTimeoutTerminatesDescendantProcessGroup() async throws {
    let runner = SystemLocalWhisperProcessRunner(
      timeout: 0.1,
      terminationGracePeriod: 0.1
    )
    let startedAt = Date()

    do {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "trap '' TERM; (trap '' TERM; sleep 3) & wait",
        ]
      )
      XCTFail("Expected the process tree to time out")
    } catch let error as LocalWhisperProcessRunnerError {
      guard case .timedOut = error else {
        return XCTFail("Unexpected runner error: \(error)")
      }
    }

    // If only the direct shell is killed, its child keeps both pipes open for
    // three seconds and the runner cannot return within this bound.
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
  }

  func testSystemRunnerCancellationTerminatesProcessAndPropagatesCancellation() async throws {
    let runner = SystemLocalWhisperProcessRunner(
      timeout: 10,
      terminationGracePeriod: 0.1
    )
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["10"]
      )
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let cancellationStartedAt = Date()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected CancellationError")
    } catch is CancellationError {
      // Expected: cancellation must remain distinguishable to the caller.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 2)
  }

  func testServiceMapsRunnerTimeoutToTranscriptionError() async throws {
    let audioURL = temporaryURL(extension: "wav")
    let modelURL = temporaryURL(extension: "bin")
    defer {
      try? FileManager.default.removeItem(at: audioURL)
      try? FileManager.default.removeItem(at: modelURL)
    }
    try Data(repeating: 0, count: 16).write(to: audioURL)
    try Data(repeating: 0, count: 16).write(to: modelURL)

    do {
      _ = try await LocalWhisperTranscriptionService(
        processRunner: TimedOutLocalWhisperRunner()
      ).transcribe(
        audioURL: audioURL,
        configuration: LocalWhisperConfiguration(
          executablePath: "/usr/bin/true",
          modelPath: modelURL.path
        )
      )
      XCTFail("Expected processTimedOut")
    } catch let error as LocalWhisperTranscriptionError {
      XCTAssertEqual(error, .processTimedOut)
    }
  }

  func testServiceRejectsOversizedTranscriptBeforeReadingIt() async throws {
    let audioURL = temporaryURL(extension: "wav")
    let modelURL = temporaryURL(extension: "bin")
    defer {
      try? FileManager.default.removeItem(at: audioURL)
      try? FileManager.default.removeItem(at: modelURL)
    }
    try Data(repeating: 0, count: 16).write(to: audioURL)
    try Data(repeating: 0, count: 16).write(to: modelURL)

    do {
      _ = try await LocalWhisperTranscriptionService(
        processRunner: OversizedTranscriptLocalWhisperRunner()
      ).transcribe(
        audioURL: audioURL,
        configuration: LocalWhisperConfiguration(
          executablePath: "/usr/bin/true",
          modelPath: modelURL.path
        )
      )
      XCTFail("Expected transcriptTooLarge")
    } catch let error as LocalWhisperTranscriptionError {
      XCTAssertEqual(error, .transcriptTooLarge)
    }
  }

  private func temporaryURL(extension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-whisper-test-\(UUID().uuidString)")
      .appendingPathExtension(`extension`)
  }
}

private struct TimedOutLocalWhisperRunner: LocalWhisperProcessRunner {
  func run(executableURL: URL, arguments: [String]) async throws -> LocalWhisperProcessResult {
    throw LocalWhisperProcessRunnerError.timedOut(seconds: 0.1)
  }
}

private struct OversizedTranscriptLocalWhisperRunner: LocalWhisperProcessRunner {
  func run(executableURL: URL, arguments: [String]) async throws -> LocalWhisperProcessResult {
    guard let outputIndex = arguments.firstIndex(of: "-of"),
          arguments.indices.contains(outputIndex + 1) else {
      return LocalWhisperProcessResult(exitCode: 1, standardOutput: "", standardError: "missing output")
    }
    let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1] + ".txt")
    _ = FileManager.default.createFile(atPath: outputURL.path, contents: Data())
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(LocalWhisperTranscriptionService.maximumTranscriptUTF8Count + 1))
    return LocalWhisperProcessResult(exitCode: 0, standardOutput: "fallback", standardError: "")
  }
}
