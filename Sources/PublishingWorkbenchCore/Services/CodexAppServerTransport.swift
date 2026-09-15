import Foundation

/// The byte-oriented transport used by ``CodexAppServerClient``.
///
/// A transport sends one JSONL request at a time and returns arbitrary stdout chunks.  Keeping
/// this boundary small makes the client straightforward to test without launching a real Codex
/// process, while the production transport below remains the only place that touches `Process`.
public protocol CodexAppServerTransport: Sendable {
  func start() async throws
  func send(_ data: Data) async throws
  func receive() async throws -> Data?
  func terminate() async
}
