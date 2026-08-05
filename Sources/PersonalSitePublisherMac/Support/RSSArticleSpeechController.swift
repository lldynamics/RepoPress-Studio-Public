@preconcurrency import AVFoundation
import Combine
import Foundation
import PublishingWorkbenchCore

@MainActor
final class RSSArticleSpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
  static let supportedRateMultipliers: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

  private static let rateDefaultsKey = "rssReaderSpeechRateMultiplier"

  let synthesizer = AVSpeechSynthesizer()

  @Published private(set) var isSpeaking = false
  @Published private(set) var isPaused = false
  @Published private(set) var currentArticleID: String?
  @Published private(set) var rateMultiplier: Double

  private var sourceText = ""
  private var speechLanguageTag: String?
  private var spokenUTF16Offset = 0
  private var utteranceStartOffset = 0
  private var currentUtterance: AVSpeechUtterance?

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
    speechLanguageTag = RSSArticleLanguageResolver.languageTag(for: article)
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
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didStart utterance: AVSpeechUtterance
  ) {
    guard utterance === currentUtterance else { return }
    isSpeaking = true
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didPause utterance: AVSpeechUtterance
  ) {
    guard utterance === currentUtterance else { return }
    isPaused = true
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didContinue utterance: AVSpeechUtterance
  ) {
    guard utterance === currentUtterance else { return }
    isPaused = false
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    guard utterance === currentUtterance else { return }
    spokenUTF16Offset = sourceText.utf16.count
    finishCurrentUtterance()
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    guard utterance === currentUtterance else { return }
    finishCurrentUtterance()
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    guard utterance === currentUtterance,
          characterRange.location != NSNotFound
    else {
      return
    }
    spokenUTF16Offset = min(
      sourceText.utf16.count,
      utteranceStartOffset + characterRange.location
    )
  }
}
