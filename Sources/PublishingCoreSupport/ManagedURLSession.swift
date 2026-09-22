import Foundation

/// URLSession retains its delegate until invalidation. This owner is shared by
/// transport value copies and creates the session only when networking starts.
/// Caller-injected sessions remain under the caller's lifecycle control.
package final class ManagedURLSession: @unchecked Sendable {
  private let lock = NSLock()
  private var cachedSession: URLSession?
  private let createSession: @Sendable () -> URLSession
  private let ownsSession: Bool

  package init(createSession: @escaping @Sendable () -> URLSession) {
    self.createSession = createSession
    ownsSession = true
  }

  package init(session: URLSession, ownsSession: Bool = false) {
    cachedSession = session
    createSession = { session }
    self.ownsSession = ownsSession
  }

  package var session: URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let cachedSession { return cachedSession }
    let session = createSession()
    cachedSession = session
    return session
  }

  package var hasCreatedSession: Bool {
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
