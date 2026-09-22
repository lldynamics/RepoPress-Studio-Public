public enum ArticleProvenance: String, CaseIterable, Identifiable, Sendable {
  case humanOriginal
  case aiAssisted
  case aiAuthored
  case hybrid

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .humanOriginal:
      return "真人原稿"
    case .aiAssisted:
      return "AI 辅助"
    case .aiAuthored:
      return "AI 主笔"
    case .hybrid:
      return "人机混合"
    }
  }

  public var systemImage: String {
    switch self {
    case .humanOriginal:
      return "person.fill"
    case .aiAssisted:
      return "wand.and.sparkles"
    case .aiAuthored:
      return "cpu"
    case .hybrid:
      return "person.2.fill"
    }
  }

  public var tag: String? {
    switch self {
    case .humanOriginal:
      return nil
    case .aiAssisted:
      return "AI辅助"
    case .aiAuthored:
      return "AI主笔"
    case .hybrid:
      return "人机混合"
    }
  }

  public var disclosureText: String? {
    switch self {
    case .humanOriginal:
      return nil
    case .aiAssisted:
      return "本文在资料整理、结构优化或文字润色过程中使用了 AI 辅助，内容由作者审核。"
    case .aiAuthored:
      return "本文主要由 AI 生成，作者可能进行了整理或编辑，请读者自行核验关键信息。"
    case .hybrid:
      return "本文由作者与 AI 共同完成，选题、判断与最终内容由作者负责。"
    }
  }
}
