import SwiftUI

struct PublishDrawerCommandAction: Sendable {
  private let perform: @MainActor @Sendable (_ message: String?, _ scope: PublishScope?) -> Void

  init(open: @escaping @MainActor @Sendable (_ message: String?, _ scope: PublishScope?) -> Void) {
    perform = open
  }

  /// A nil scope keeps the drawer's default; entry points tied to one article
  /// pass `.currentArticle` so the drawer matches what they just checked.
  @MainActor
  func open(_ message: String?, scope: PublishScope? = nil) {
    perform(message, scope)
  }
}

private struct PublishDrawerCommandActionKey: FocusedValueKey {
  typealias Value = PublishDrawerCommandAction
}

private struct PublishDrawerCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: PublishDrawerCommandAction? = nil
}

extension FocusedValues {
  var publishDrawerCommandAction: PublishDrawerCommandAction? {
    get { self[PublishDrawerCommandActionKey.self] }
    set { self[PublishDrawerCommandActionKey.self] = newValue }
  }
}

extension EnvironmentValues {
  var publishDrawerCommandAction: PublishDrawerCommandAction? {
    get { self[PublishDrawerCommandActionEnvironmentKey.self] }
    set { self[PublishDrawerCommandActionEnvironmentKey.self] = newValue }
  }
}
