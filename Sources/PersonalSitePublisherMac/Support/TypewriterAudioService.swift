import AppKit
import AudioToolbox
import Foundation

enum TypewriterSoundPreset: String, CaseIterable, Identifiable {
  case off
  case typewriter
  case mechanical
  case softClick

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: return String(localized: "关闭")
    case .typewriter: return String(localized: "经典打字机")
    case .mechanical: return String(localized: "机械键盘")
    case .softClick: return String(localized: "柔和点击")
    }
  }
}

@MainActor
final class TypewriterAudioService {
  static let shared = TypewriterAudioService()

  private let typewriterSound = NSSound(named: NSSound.Name("Tink"))
  private let softClickSound = NSSound(named: NSSound.Name("Pop"))
  private var lastPlaybackUptime: TimeInterval?

  private init() {}

  func playKeyClick(preset: TypewriterSoundPreset) {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = lastPlaybackUptime.map { now - $0 }
    guard MarkdownTypingFeedbackPolicy.shouldPlay(
      for: .insertedText,
      preset: preset,
      elapsedSincePreviousPlayback: elapsed
    ) else { return }
    lastPlaybackUptime = now

    // 触发 macOS 触控板 Alignment 级微触觉反馈
    NSHapticFeedbackManager.defaultPerformer.perform(
      .alignment,
      performanceTime: .now
    )

    // 根据预设播放音效
    switch preset {
    case .typewriter:
      typewriterSound?.play()
    case .mechanical:
      AudioServicesPlaySystemSound(1104)
    case .softClick:
      softClickSound?.play()
    case .off:
      break
    }
  }
}
