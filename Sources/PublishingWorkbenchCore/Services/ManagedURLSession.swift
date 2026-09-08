import Foundation

/// URLSession retains its delegate until invalidation. This owner is shared by
/// transport value copies and creates the session only when networking starts.
/// Caller-injected sessions remain under the caller's lifecycle control.
final class ManagedURLSession: @unchecked Sendable {
  private let lock = NSLock()
  private var cachedSession: URLSession?
  private let createSession: @Sendable () -> URLSession
  private let ownsSession: Bool

  init(createSession: @escaping @Sendable () -> URLSession) {
    self.createSession = createSession
    ownsSession = true
  }

  init(session: URLSession, ownsSession: Bool = false) {
    cachedSession = session
    createSession = { session }
    self.ownsSession = ownsSession
  }

  var session: URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let cachedSession { return cachedSession }
    let session = createSession()
    cachedSession = session
    return session
  }

  var hasCreatedSession: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cachedSession != nil
  }

  deinit {
    if ownsSession {
      cachedSession?.finishTasksAndInvalidate()
    }
  }
}
