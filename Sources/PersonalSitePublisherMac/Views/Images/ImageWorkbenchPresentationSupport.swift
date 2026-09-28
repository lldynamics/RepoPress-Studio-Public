import PublishingDomainContracts
import SwiftUI

struct RepositoryInventoryRefreshInput: Hashable {
  let requestID: UUID
  let imageRevision: UInt64
  let profileID: UUID
  let repositoryRootPath: String
  let assetRoot: String
  let stage: ImageWorkbenchContextStage
  let resourceMode: ImageWorkbenchResourceMode
}

enum ImageWorkbenchResourceMode: String, CaseIterable, Identifiable, Hashable {
  case repository
  case manager

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .repository:
      return "仓库图片"
    case .manager:
      return "资源管理"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .repository:
      return String(localized: "仓库图片")
    case .manager:
      return String(localized: "资源管理")
    }
  }

  var systemImage: String {
    switch self {
    case .repository:
      return "photo.stack"
    case .manager:
      return "archivebox"
    }
  }

  var description: LocalizedStringKey {
    switch self {
    case .repository:
      return "浏览仓库中的图片、查看引用关系，并把图片加入目标文章。"
    case .manager:
      return "扫描全仓库 Markdown 引用，清理孤立资源并安全压缩大图。"
    }
  }
}

enum ImageWorkbenchResourceNavigationDestination: Equatable {
  case assetResourceManager
}

enum ImageWorkbenchResourceNavigationPolicy {
  static func destination(
    for request: AssetResourceManagerNavigationRequest,
    activeProfileID: UUID,
    windowID: UUID? = nil
  ) -> ImageWorkbenchResourceNavigationDestination? {
    guard request.profileID == activeProfileID, request.windowID == windowID else { return nil }
    return .assetResourceManager
  }
}

struct ImageWorkbenchBatchCardStyle: ButtonStyle {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let isAvailable: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity)
      .background(
        isAvailable ? workbenchAccentColor.opacity(0.08) : Color.primary.opacity(0.025),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(
            isAvailable ? workbenchAccentColor.opacity(0.12) : Color.primary.opacity(0.08)
          )
      }
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}
