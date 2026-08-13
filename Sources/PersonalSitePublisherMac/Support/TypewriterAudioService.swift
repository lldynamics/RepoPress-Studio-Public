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
    case .off: return "关闭"
    case .typewriter: return "经典打字机"
    case .mechanical: return "机械键盘"
    case .softClick: return "柔和点击"
    }
  }
}

@MainActor
final class TypewriterAudioService {
  static let shared = TypewriterAudioService()

  private init() {}

  func playKeyClick(preset: TypewriterSoundPreset) {
    guard preset != .off else { return }

    // 触发 macOS 触控板 Alignment 级微触觉反馈
    NSHapticFeedbackManager.defaultPerformer.perform(
      .alignment,
      performanceTime: .now
    )

    // 根据预设播放音效
    switch preset {
    case .typewriter:
      NSSound(named: NSSound.Name("Tink"))?.play()
    case .mechanical:
      AudioServicesPlaySystemSound(1104)
    case .softClick:
      NSSound(named: NSSound.Name("Pop"))?.play()
    case .off:
      break
    }
  }
}
