import PublishingAICore
import SwiftUI

enum AIConnectionKind: String, CaseIterable, Identifiable {
  case chatGPT
  case local
  case apiKey

  var id: String { rawValue }

  init(preset: AIProviderPreset) {
    switch preset {
    case .codexAppServer:
      self = .chatGPT
    case .local:
      self = .local
    case .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow, .moonshot, .zhipu,
      .openRouter, .custom:
      self = .apiKey
    }
  }

  var title: String {
    switch self {
    case .chatGPT: return String(localized: "ChatGPT 登录")
    case .local: return String(localized: "本地模型")
    case .apiKey: return "API Key"
    }
  }

  var systemImage: String {
    switch self {
    case .chatGPT: return "person.crop.circle.badge.checkmark"
    case .local: return "desktopcomputer"
    case .apiKey: return "key.fill"
    }
  }
}

struct AIProviderFieldPresentation: Equatable {
  let showsConnectionFieldsByDefault: Bool

  init(config: AIProviderConfig) {
    showsConnectionFieldsByDefault =
      config.preset == .custom || config.preset == .local
      || AIProviderSetupGuide.guide(for: config) == nil || !config.requiresAPIKey
  }
}
