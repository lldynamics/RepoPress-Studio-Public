#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  import Foundation

  public enum ScreenshotDemoSurface: String, CaseIterable, Identifiable, Sendable {
    case writing
    case aiChat = "ai-chat"
    case syncAPIPublish = "sync-api-publish"
    case seoSocialPreview = "seo-social-preview"
    case deploymentStatus = "deployment-status"
    case maintenance
    case settings
    case generalDrafts = "general-drafts"
    case knowledgeLibrary = "knowledge-library"

    public var id: String { rawValue }

    @MainActor
    public func apply(to store: WorkbenchStore) {
      if let draft = preferredDraft(in: store) {
        store.selectDraft(draft.id)
      }

      switch self {
      case .writing:
        store.selectSection(.writing)
        store.setPublishActionMessage(String(localized: "截图模式：写作工作区已载入演示文章。"), status: .information)
      case .aiChat:
        _ = store.openAIChatWorkspace(for: preferredDraft(in: store)?.id)
        store.seedTransientAIChatPreview([
          AIPublishingChatMessage(
            role: .user,
            content: "请从发布前角度检查这篇文章的标题、摘要、SEO 和发布风险。",
            contextMode: .site
          ),
          AIPublishingChatMessage(
            role: .assistant,
            content: "标题清晰，摘要覆盖写作、SEO、线上发布和部署校验。建议保留 Open Graph 图片，并在发布前确认远端冲突预览为空。",
            model: "custom-review-model",
            contextMode: .site
          ),
        ])
        store.setInspectorPresented(false)
        store.setPublishActionMessage(
          String(localized: "截图模式：免费自定义 API 的 AI 助手已载入。"), status: .information)
      case .syncAPIPublish:
        store.selectSection(.sync)
        store.setPublishActionMessage(
          String(localized: "截图模式：同步/API 发布工作区已载入。"), status: .information)
      case .seoSocialPreview:
        store.selectSection(.writing)
        store.setInspectorPresented(true)
        if let draft = preferredDraft(in: store) {
          store.refreshSEOSocialPreview(for: draft, message: "截图模式：SEO / 社交预览快照已载入。")
        }
      case .deploymentStatus:
        store.selectSection(.sync)
        store.setDeploymentStatusMessage("截图模式：部署状态和轮询记录已载入。")
      case .maintenance:
        store.selectSection(.contentHealth)
        store.setPublishActionMessage(String(localized: "截图模式：站点维护工作台已载入。"), status: .information)
      case .settings:
        store.selectSection(.writing)
        store.setPublishActionMessage(String(localized: "截图模式：统一设置工作区已载入。"), status: .information)
      case .generalDrafts:
        store.selectSection(.writing)
        store.setDraftListContentScope(.general)
        store.setPublishActionMessage(String(localized: "截图模式：通用草稿已载入。"), status: .information)
      case .knowledgeLibrary:
        store.selectSection(.library)
        store.setInspectorPresented(false)
        store.setPublishActionMessage(String(localized: "截图模式：本地资料库已载入。"), status: .information)
      }
    }

    @MainActor
    private func preferredDraft(in store: WorkbenchStore) -> ArticleDraft? {
      store.visibleDrafts.first { $0.status == .ready && !$0.isPrivate }
        ?? store.visibleDrafts.first { !$0.isPrivate }
        ?? store.visibleDrafts.first
    }
  }
#endif
