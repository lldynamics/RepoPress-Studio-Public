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

enum MarkdownTypingFeedbackEvent: Equatable {
  case insertedText
  case command
  case navigation
  case other
}

enum MarkdownTypingFeedbackPolicy {
  static let defaultPreset = TypewriterSoundPreset.off
  static let minimumPlaybackInterval: TimeInterval = 0.03

  static func event(
    keyCode: UInt16,
    characters: String?,
    modifiers: NSEvent.ModifierFlags
  ) -> MarkdownTypingFeedbackEvent {
    let relevantModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
    if relevantModifiers.contains(.command) || relevantModifiers.contains(.control) {
      return .command
    }

    switch keyCode {
    case 36, 48, 53, 76, 115, 116, 117, 118, 119, 121, 123, 124, 125, 126:
      return .navigation
    default:
      break
    }

    guard let characters, !characters.isEmpty else { return .other }
    let isPrintable = characters.unicodeScalars.contains {
      $0.value >= 0x20 && $0.value != 0x7F
    }
    return isPrintable ? .insertedText : .other
  }

  static func shouldPlay(
    for event: MarkdownTypingFeedbackEvent,
    preset: TypewriterSoundPreset,
    elapsedSincePreviousPlayback: TimeInterval? = nil
  ) -> Bool {
    guard event == .insertedText, preset != .off else { return false }
    guard let elapsedSincePreviousPlayback else { return true }
    return elapsedSincePreviousPlayback >= minimumPlaybackInterval
  }
}
