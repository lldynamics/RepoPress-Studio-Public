import Foundation

enum WorkbenchShortcutRequest: Equatable, Sendable {
  case newArticle
  case publishCurrentArticle
  case siteChecks
  case openArticle(UUID)

  init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "repopress", components.user == nil, components.password == nil,
      components.port == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { return nil }
    let items = components.queryItems ?? []
    switch components.host {
    case "new-article" where items.isEmpty: self = .newArticle
    case "publish-current" where items.isEmpty: self = .publishCurrentArticle
    case "site-checks" where items.isEmpty: self = .siteChecks
    case "open-article" where items.count == 1 && items[0].name == "id":
      guard let value = items[0].value, let id = UUID(uuidString: value) else { return nil }
      self = .openArticle(id)
    default: return nil
    }
  }
}

/// Cold-launch requests wait for a ready key window. Background windows never
/// consume a command intended for the window the person is using.
@MainActor
final class WorkbenchShortcutCoordinator {
  static let shared = WorkbenchShortcutCoordinator()
  private var pending: [WorkbenchShortcutRequest] = []
  private var handlers: [UUID: (WorkbenchShortcutRequest) -> Void] = [:]
  private var keyWindowID: UUID?
  private(set) var pendingCount = 0

  func enqueue(_ request: WorkbenchShortcutRequest) {
    guard pending.count < 16 else { return }
    pending.append(request)
    pendingCount = pending.count
    drain()
  }

  func register(
    windowID: UUID, isKeyWindow: Bool,
    handler: @escaping (WorkbenchShortcutRequest) -> Void
  ) {
    handlers[windowID] = handler
    if isKeyWindow { keyWindowID = windowID } else if keyWindowID == windowID { keyWindowID = nil }
    drain()
  }

  func unregister(windowID: UUID) {
    handlers.removeValue(forKey: windowID)
    if keyWindowID == windowID { keyWindowID = nil }
  }

  private func drain() {
    guard let keyWindowID, let handler = handlers[keyWindowID], !pending.isEmpty else { return }
    let requests = pending
    pending.removeAll()
    pendingCount = 0
    for request in requests { handler(request) }
  }
}
