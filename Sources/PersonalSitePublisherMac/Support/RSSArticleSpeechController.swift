@preconcurrency import AVFoundation
import Combine
import Foundation
import PublishingWorkbenchCore

struct RSSArticleSpeechHighlight: Equatable, Sendable {
  let location: Int
  let length: Int
  let text: String
}

@MainActor
final class RSSArticleSpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  static let supportedRateMultipliers: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

  private static let rateDefaultsKey = "rssReaderSpeechRateMultiplier"

  let synthesizer = AVSpeechSynthesizer()

  @Published private(set) var isSpeaking = false
  @Published private(set) var isPaused = false
  @Published private(set) var currentArticleID: String?
  @Published private(set) var currentSpeechHighlight: RSSArticleSpeechHighlight?
  @Published private(set) var rateMultiplier: Double

  private var sourceText = ""
  private var speechLanguageTag: String?
  private var spokenUTF16Offset = 0
  private var utteranceStartOffset = 0
  private var currentUtterance: AVSpeechUtterance?
  private var sentenceRanges: [NSRange] = []
  private var currentSentenceIndex = 0

  override init() {
    let storedRate = UserDefaults.standard.double(forKey: Self.rateDefaultsKey)
    rateMultiplier = Self.normalizedRateMultiplier(storedRate == 0 ? 1.0 : storedRate)
    super.init()
    synthesizer.delegate = self
  }

  func toggle(article: RSSArticle) {
    if currentArticleID == article.id, isSpeaking {
      if isPaused {
        resume()
      } else {
        pause()
      }
      return
    }
    start(article: article)
  }

  func start(article: RSSArticle) {
    stop()

    let text = article.readableText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    sourceText = text
    currentArticleID = article.id
    currentSpeechHighlight = nil
    speechLanguageTag = RSSArticleLanguageResolver.languageTag(for: article)
    sentenceRanges = Self.sentenceRanges(in: text)
    currentSentenceIndex = 0
    spokenUTF16Offset = 0
    speakRemaining(from: 0, paused: false)
  }

  func pause() {
    guard isSpeaking, !isPaused else { return }
    if synthesizer.pauseSpeaking(at: .immediate) {
      isPaused = true
    }
  }

  func resume() {
    guard isSpeaking, isPaused else { return }
    if synthesizer.continueSpeaking() {
      isPaused = false
    }
  }

  func stop() {
    currentUtterance = nil
    _ = synthesizer.stopSpeaking(at: .immediate)
    resetState()
  }

  func setRateMultiplier(_ value: Double) {
    let normalized = Self.normalizedRateMultiplier(value)
    guard normalized != rateMultiplier else { return }

    rateMultiplier = normalized
    UserDefaults.standard.set(normalized, forKey: Self.rateDefaultsKey)

    guard isSpeaking, currentUtterance != nil else { return }
    restartFromCurrentPosition()
  }

  static func normalizedRateMultiplier(_ value: Double) -> Double {
    min(max(value.isFinite ? value : 1.0, 1.0), 2.0)
  }

  static func speechHighlight(
    in text: String,
    around range: NSRange
  ) -> RSSArticleSpeechHighlight? {
    let ranges = sentenceRanges(in: text)
    var sentenceIndex = 0
    return makeSpeechHighlight(
      in: text,
      around: range,
      sentenceRanges: ranges,
      sentenceIndex: &sentenceIndex
    )
  }

  private func speakRemaining(from offset: Int, paused: Bool) {
    let safeOffset = min(max(offset, 0), sourceText.utf16.count)
    let remainingText = (sourceText as NSString).substring(from: safeOffset)
    guard !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      finishCurrentUtterance()
      return
    }

    let utterance = AVSpeechUtterance(string: remainingText)
    utterance.rate = speechRate
    if let speechLanguageTag,
       speechLanguageTag != "und",
       let voice = AVSpeechSynthesisVoice(language: speechLanguageTag) {
      utterance.voice = voice
    }

    utteranceStartOffset = safeOffset
    currentUtterance = utterance
    isSpeaking = true
    isPaused = false
    synthesizer.speak(utterance)

    if paused {
      _ = synthesizer.pauseSpeaking(at: .immediate)
      isPaused = true
    }
  }

  private func restartFromCurrentPosition() {
    guard currentArticleID != nil, currentUtterance != nil else { return }

    let offset = spokenUTF16Offset
    let shouldPause = isPaused
    currentUtterance = nil
    _ = synthesizer.stopSpeaking(at: .immediate)
    speakRemaining(from: offset, paused: shouldPause)
  }

  private var speechRate: Float {
    let scaledRate = AVSpeechUtteranceDefaultSpeechRate * Float(rateMultiplier)
    return min(
      max(scaledRate, AVSpeechUtteranceMinimumSpeechRate),
      AVSpeechUtteranceMaximumSpeechRate
    )
  }

  private func finishCurrentUtterance() {
    currentUtterance = nil
    resetState()
  }

  private func resetState() {
    isSpeaking = false
    isPaused = false
    currentArticleID = nil
    sourceText = ""
    speechLanguageTag = nil
    spokenUTF16Offset = 0
    utteranceStartOffset = 0
    currentSpeechHighlight = nil
    sentenceRanges = []
    currentSentenceIndex = 0
  }

  private nonisolated func performOnMainActor(
    _ operation: @escaping @MainActor @Sendable (RSSArticleSpeechController) -> Void
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      operation(self)
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didStart utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    performOnMainActor { controller in
      guard controller.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
      controller.isSpeaking = true
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didPause utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    performOnMainActor { controller in
      guard controller.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
      controller.isPaused = true
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didContinue utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    performOnMainActor { controller in
      guard controller.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
      controller.isPaused = false
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    performOnMainActor { controller in
      guard controller.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
      controller.spokenUTF16Offset = controller.sourceText.utf16.count
      controller.finishCurrentUtterance()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    performOnMainActor { controller in
      guard controller.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
      controller.finishCurrentUtterance()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    performOnMainActor { controller in
      guard controller.currentUtterance.map(ObjectIdentifier.init) == utteranceID,
            characterRange.location != NSNotFound
      else {
        return
      }
      controller.spokenUTF16Offset = min(
        controller.sourceText.utf16.count,
        controller.utteranceStartOffset + characterRange.location
      )
      let absoluteRange = NSRange(
        location: controller.spokenUTF16Offset,
        length: min(
          characterRange.length,
          max(0, controller.sourceText.utf16.count - controller.spokenUTF16Offset)
        )
      )
      let nextHighlight = Self.makeSpeechHighlight(
        in: controller.sourceText,
        around: absoluteRange,
        sentenceRanges: controller.sentenceRanges,
        sentenceIndex: &controller.currentSentenceIndex
      )
      if nextHighlight != controller.currentSpeechHighlight {
        controller.currentSpeechHighlight = nextHighlight
      }
    }
  }

  private static func sentenceRanges(in text: String) -> [NSRange] {
    guard !text.isEmpty else { return [] }

    var ranges: [NSRange] = []
    text.enumerateSubstrings(
      in: text.startIndex..<text.endIndex,
      options: [.bySentences, .substringNotRequired]
    ) { _, substringRange, _, _ in
      ranges.append(NSRange(substringRange, in: text))
    }
    return ranges
  }

  private static func makeSpeechHighlight(
    in text: String,
    around range: NSRange,
    sentenceRanges: [NSRange],
    sentenceIndex: inout Int
  ) -> RSSArticleSpeechHighlight? {
    let source = text as NSString
    guard source.length > 0 else { return nil }

    let location = min(max(range.location, 0), source.length - 1)
    let length = min(max(range.length, 1), source.length - location)
    let targetRange = NSRange(location: location, length: length)

    var selectedRange = targetRange
    if !sentenceRanges.isEmpty {
      var selectedIndex = sentenceIndex
      selectedIndex = min(max(selectedIndex, 0), sentenceRanges.count - 1)
      if targetRange.location < sentenceRanges[selectedIndex].location {
        selectedIndex = 0
      }
      while selectedIndex + 1 < sentenceRanges.count,
            targetRange.location >= NSMaxRange(sentenceRanges[selectedIndex]) {
        selectedIndex += 1
      }

      let candidate = sentenceRanges[selectedIndex]
      if NSIntersectionRange(candidate, targetRange).length > 0 {
        selectedRange = candidate
      } else if let matchingRange = sentenceRanges.first(where: {
        NSIntersectionRange($0, targetRange).length > 0
      }) {
        selectedRange = matchingRange
        selectedIndex = sentenceRanges.firstIndex(of: matchingRange) ?? selectedIndex
      }
      sentenceIndex = selectedIndex
    }

    let highlightedText = source.substring(with: selectedRange)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !highlightedText.isEmpty else { return nil }
    return RSSArticleSpeechHighlight(
      location: selectedRange.location,
      length: selectedRange.length,
      text: highlightedText
    )
  }
}
