import AppKit
import Foundation

enum MarkdownSlashCommandKey: Equatable {
  case moveUp
  case moveDown
  case select
  case dismiss

  static func from(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> Self? {
    // AppKit can attach `.function` to arrow keys and `.numericPad` to the
    // keypad Enter key. Those describe the physical key, not a user shortcut,
    // so only reject modifiers that intentionally alter the command.
    let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
    guard shortcutModifiers.isEmpty else { return nil }

    switch keyCode {
    case 126:
      return .moveUp
    case 125:
      return .moveDown
    case 36, 76:
      return .select
    case 53:
      return .dismiss
    default:
      return nil
    }
  }
}

enum MarkdownSlashCommandSelection {
  static func move(
    currentIndex: Int,
    itemCount: Int,
    direction: MarkdownSlashCommandKey
  ) -> Int {
    guard itemCount > 0 else { return 0 }
    let current = min(max(currentIndex, 0), itemCount - 1)
    switch direction {
    case .moveUp:
      return current == 0 ? itemCount - 1 : current - 1
    case .moveDown:
      return current == itemCount - 1 ? 0 : current + 1
    case .select, .dismiss:
      return current
    }
  }
}

enum MarkdownSlashCommandText {
  static func query(in body: String, caretUTF16Location: Int) -> String? {
    let source = body as NSString
    guard caretUTF16Location > 0, caretUTF16Location <= source.length else {
      return nil
    }

    let textUpToCaret = source.substring(to: caretUTF16Location)
    guard let lastLine = textUpToCaret.components(separatedBy: .newlines).last,
      lastLine.hasPrefix("/")
    else {
      return nil
    }
    return String(lastLine.dropFirst())
  }

  static func replacementRange(
    in body: String,
    caretUTF16Location: Int
  ) -> NSRange? {
    let source = body as NSString
    guard caretUTF16Location > 0, caretUTF16Location <= source.length else {
      return nil
    }

    let textUpToCaret = source.substring(to: caretUTF16Location)
    guard let lastLine = textUpToCaret.components(separatedBy: .newlines).last,
      lastLine.hasPrefix("/")
    else {
      return nil
    }

    let lineLength = (lastLine as NSString).length
    guard lineLength <= caretUTF16Location else { return nil }
    return NSRange(
      location: caretUTF16Location - lineLength,
      length: lineLength
    )
  }
}
