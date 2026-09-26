import Foundation
import SwiftUI

enum MarkdownEditorComfortPreferences {
  static let fontSizeKey = "markdownEditorFontSize"
  static let lineSpacingKey = "markdownEditorLineSpacing"
  static let bodyWidthKey = "markdownEditorBodyWidth"
  static let spellCheckEnabledKey = "markdownEditorSpellCheckEnabled"
  static let typewriterModeEnabledKey = "markdownEditorTypewriterModeEnabled"
  static let currentParagraphHighlightEnabledKey = "markdownEditorCurrentParagraphHighlightEnabled"
  static let warmPaperBackgroundEnabledKey = "markdownEditorWarmPaperBackgroundEnabled"
  static let automaticPairingEnabledKey = "markdownEditorAutomaticPairingEnabled"
  static let paragraphSpotlightEnabledKey = "markdownEditorParagraphSpotlightEnabled"
  static let realtimeAnalysisEnabledKey = "markdownEditorRealtimeAnalysisEnabled"
  static let bodyFontStyleKey = "markdownEditorBodyFontStyle"

  static let defaultRealtimeAnalysisEnabled = true
}

/// Shared gate for work that may be triggered by editor input.
///
/// Manual commands are always allowed; persisted switches only control work
/// requested as a consequence of an input change or preference update.
enum MarkdownEditorAutomationPolicy {
  /// Full-document automation waits until the editor has been quiet before it
  /// starts. Keeping this in one policy makes the debounce observable in tests
  /// and keeps diagnostics and SSG derived data on the same cadence.
  static let automaticWorkIdleDelayMilliseconds = 1_200

  static var automaticWorkIdleDelay: Duration {
    .milliseconds(automaticWorkIdleDelayMilliseconds)
  }

  static func allows(isAutomatic: Bool, isEnabled: Bool) -> Bool {
    !isAutomatic || isEnabled
  }
}

/// Prose and code use different typefaces: long-form writing reads best in a
/// proportional face, while code spans and fences always stay monospaced.
enum MarkdownEditorBodyFontStyle: String, CaseIterable, Identifiable {
  case proportional
  case serif
  case monospaced

  static let defaultStyle = MarkdownEditorBodyFontStyle.proportional

  var id: String { rawValue }

  var title: String {
    switch self {
    case .proportional: String(localized: "无衬线")
    case .serif: String(localized: "衬线")
    case .monospaced: String(localized: "等宽")
    }
  }

  static func resolved(rawValue: String?) -> MarkdownEditorBodyFontStyle {
    rawValue.flatMap(Self.init(rawValue:)) ?? defaultStyle
  }

  var previewDesign: Font.Design {
    switch self {
    case .proportional: .default
    case .serif: .serif
    case .monospaced: .monospaced
    }
  }
}

struct MarkdownEditorComfortConfiguration: Equatable {
  static let fontSizeRange = 12.0...24.0
  static let lineSpacingRange = 0.0...12.0
  static let bodyWidthRange = 560.0...1_200.0

  static let defaultFontSize = 14.0
  static let defaultLineSpacing = 4.0
  static let defaultBodyWidth = 720.0
  static let defaultSpellCheckEnabled = false
  static let defaultTypewriterModeEnabled = false
  static let defaultCurrentParagraphHighlightEnabled = true
  static let defaultWarmPaperBackgroundEnabled = false
  static let defaultAutomaticPairingEnabled = true
  static let defaultParagraphSpotlightEnabled = false
  static let defaultRealtimeAnalysisEnabled = MarkdownEditorComfortPreferences
    .defaultRealtimeAnalysisEnabled

  let fontSize: Double
  let lineSpacing: Double
  let bodyWidth: Double
  let bodyFontStyle: MarkdownEditorBodyFontStyle
  let spellCheckEnabled: Bool
  let typewriterModeEnabled: Bool
  let currentParagraphHighlightEnabled: Bool
  let warmPaperBackgroundEnabled: Bool
  let automaticPairingEnabled: Bool
  let accessibilityReduceMotionEnabled: Bool

  init(
    fontSize: Double = defaultFontSize,
    lineSpacing: Double = defaultLineSpacing,
    bodyWidth: Double = defaultBodyWidth,
    bodyFontStyle: MarkdownEditorBodyFontStyle = .defaultStyle,
    spellCheckEnabled: Bool = defaultSpellCheckEnabled,
    typewriterModeEnabled: Bool = defaultTypewriterModeEnabled,
    currentParagraphHighlightEnabled: Bool = defaultCurrentParagraphHighlightEnabled,
    warmPaperBackgroundEnabled: Bool = defaultWarmPaperBackgroundEnabled,
    automaticPairingEnabled: Bool = defaultAutomaticPairingEnabled,
    accessibilityReduceMotionEnabled: Bool = false
  ) {
    self.fontSize = fontSize.clamped(to: Self.fontSizeRange)
    self.lineSpacing = lineSpacing.clamped(to: Self.lineSpacingRange)
    self.bodyWidth = bodyWidth.clamped(to: Self.bodyWidthRange)
    self.bodyFontStyle = bodyFontStyle
    self.spellCheckEnabled = spellCheckEnabled
    self.typewriterModeEnabled = typewriterModeEnabled
    self.currentParagraphHighlightEnabled = currentParagraphHighlightEnabled
    self.warmPaperBackgroundEnabled = warmPaperBackgroundEnabled
    self.automaticPairingEnabled = automaticPairingEnabled
    self.accessibilityReduceMotionEnabled = accessibilityReduceMotionEnabled
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
