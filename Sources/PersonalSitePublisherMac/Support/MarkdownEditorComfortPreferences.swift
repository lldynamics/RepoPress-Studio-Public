import Foundation

enum MarkdownEditorComfortPreferences {
  static let fontSizeKey = "markdownEditorFontSize"
  static let lineSpacingKey = "markdownEditorLineSpacing"
  static let bodyWidthKey = "markdownEditorBodyWidth"
  static let spellCheckEnabledKey = "markdownEditorSpellCheckEnabled"
  static let typewriterModeEnabledKey = "markdownEditorTypewriterModeEnabled"
  static let currentParagraphHighlightEnabledKey = "markdownEditorCurrentParagraphHighlightEnabled"
  static let warmPaperBackgroundEnabledKey = "markdownEditorWarmPaperBackgroundEnabled"
  static let automaticPairingEnabledKey = "markdownEditorAutomaticPairingEnabled"
  static let writingGoalKey = "markdownEditorWritingGoal"
}

enum AIWritingPreferences {
  static let automaticInlineCompletionEnabledKey = "ai.automaticInlineCompletionEnabled"
  static let defaultAutomaticInlineCompletionEnabled = false
}

struct MarkdownEditorComfortConfiguration: Equatable {
  static let fontSizeRange = 12.0 ... 24.0
  static let lineSpacingRange = 0.0 ... 12.0
  static let bodyWidthRange = 560.0 ... 1_200.0

  static let defaultFontSize = 14.0
  static let defaultLineSpacing = 4.0
  static let defaultBodyWidth = 820.0
  static let defaultSpellCheckEnabled = false
  static let defaultTypewriterModeEnabled = false
  static let defaultCurrentParagraphHighlightEnabled = true
  static let defaultWarmPaperBackgroundEnabled = false
  static let defaultAutomaticPairingEnabled = true
  static let defaultWritingGoal = 1_500

  let fontSize: Double
  let lineSpacing: Double
  let bodyWidth: Double
  let spellCheckEnabled: Bool
  let typewriterModeEnabled: Bool
  let currentParagraphHighlightEnabled: Bool
  let warmPaperBackgroundEnabled: Bool
  let automaticPairingEnabled: Bool

  init(
    fontSize: Double = defaultFontSize,
    lineSpacing: Double = defaultLineSpacing,
    bodyWidth: Double = defaultBodyWidth,
    spellCheckEnabled: Bool = defaultSpellCheckEnabled,
    typewriterModeEnabled: Bool = defaultTypewriterModeEnabled,
    currentParagraphHighlightEnabled: Bool = defaultCurrentParagraphHighlightEnabled,
    warmPaperBackgroundEnabled: Bool = defaultWarmPaperBackgroundEnabled,
    automaticPairingEnabled: Bool = defaultAutomaticPairingEnabled
  ) {
    self.fontSize = fontSize.clamped(to: Self.fontSizeRange)
    self.lineSpacing = lineSpacing.clamped(to: Self.lineSpacingRange)
    self.bodyWidth = bodyWidth.clamped(to: Self.bodyWidthRange)
    self.spellCheckEnabled = spellCheckEnabled
    self.typewriterModeEnabled = typewriterModeEnabled
    self.currentParagraphHighlightEnabled = currentParagraphHighlightEnabled
    self.warmPaperBackgroundEnabled = warmPaperBackgroundEnabled
    self.automaticPairingEnabled = automaticPairingEnabled
  }
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
