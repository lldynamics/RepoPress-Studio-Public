import SwiftUI

struct PublishDrawerCommandAction: Sendable {
  let open: @MainActor @Sendable (_ message: String?) -> Void
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
