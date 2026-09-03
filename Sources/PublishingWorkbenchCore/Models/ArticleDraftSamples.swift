import Foundation

extension ArticleDraft {
  public static func empty(profile: SiteProfile) -> ArticleDraft {
    let now = Date()
    return ArticleDraft(
      siteProfileID: profile.id,
      title: "未命名文章",
      date: now,
      slug: SlugService.fallbackSlug(date: now),
      tags: profile.defaultTags,
      categories: profile.defaultCategories,
      authors: profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? [],
      bodyMarkdown: "# 未命名文章\n\n从这里开始写作。\n"
    )
  }

  public static func emptyGeneralDraft(editingProfile: SiteProfile) -> ArticleDraft {
    let now = Date()
    return ArticleDraft(
      siteProfileID: editingProfile.id,
      scope: .general,
      title: "未命名草稿",
      date: now,
      slug: SlugService.fallbackSlug(date: now),
      bodyMarkdown: "# 未命名草稿\n\n从这里开始写作。\n"
    )
  }

  /// Creates safe, editable guides for a brand-new workbench.
  ///
  /// Every guide remains a draft and has no repository path, so opening the
  /// application for the first time can never publish or overwrite a file.
  public static func samples(
    profile: SiteProfile,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> [ArticleDraft] {
    let templates = sampleTemplates(preferredLanguage: preferredLanguage)
    let authors = profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? []

    return templates.enumerated().map { index, template in
      let timestamp = now.addingTimeInterval(-TimeInterval(index * 60))
      return ArticleDraft(
        siteProfileID: profile.id,
        scope: .general,
        title: template.title,
        date: timestamp,
        slug: template.slug,
        tags: template.tags,
        categories: template.categories,
        authors: authors,
        draft: true,
        summary: template.summary,
        bodyMarkdown: template.bodyMarkdown,
        status: .draft,
        createdAt: timestamp,
        updatedAt: timestamp,
        softwareGuideID: template.id,
        softwareGuideTemplateVersion: currentSoftwareGuideSeedVersion
      )
    }
  }

  public static let currentSoftwareGuideSeedVersion = 5

  public struct SoftwareGuideSynchronizationResult: Sendable {
    public let drafts: [ArticleDraft]
    public let addedGuideCount: Int
    public let refreshedGuideCount: Int
  }

  /// Returns only the guides that are missing from the supplied drafts.
  ///
  /// Guide identity is independent from editable slugs. If a user-owned draft
  /// already occupies a guide slug, the new guide receives a numeric suffix
  /// instead of replacing or reclassifying the user's content.
  public static func missingSoftwareGuides(
    in existingDrafts: [ArticleDraft],
    profile: SiteProfile,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> [ArticleDraft] {
    let guides = samples(
      profile: profile,
      preferredLanguage: preferredLanguage,
      now: now
    )
    let installedGuideIDs = Set(existingDrafts.compactMap(\.softwareGuideID))
    var occupiedSlugs = Set(
      existingDrafts.map { $0.slug.trimmedForPublishing.lowercased() }
    )

    return
      guides
      .filter { guide in
        guard let guideID = guide.softwareGuideID else { return false }
        return !installedGuideIDs.contains(guideID)
      }
      .map { guide in
        var resolvedGuide = guide
        let baseSlug = guide.slug
        var candidateSlug = baseSlug
        var suffix = 2
        while occupiedSlugs.contains(candidateSlug.trimmedForPublishing.lowercased()) {
          candidateSlug = "\(baseSlug)-\(suffix)"
          suffix += 1
        }
        resolvedGuide.slug = candidateSlug
        occupiedSlugs.insert(candidateSlug.trimmedForPublishing.lowercased())
        return resolvedGuide
      }
  }

  /// Installs newly introduced guides and refreshes unchanged built-in guides.
  ///
  /// Startup migrations do not restore guides that the user removed in an
  /// earlier version. An explicit Help-menu installation can opt into
  /// restoring every missing guide.
  public static func synchronizeSoftwareGuides(
    in existingDrafts: [ArticleDraft],
    profile: SiteProfile,
    previousSeedVersion: Int,
    restorePreviouslyRemovedGuides: Bool = false,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> SoftwareGuideSynchronizationResult {
    let templates = samples(
      profile: profile,
      preferredLanguage: preferredLanguage,
      now: now
    )
    let templatesByID = Dictionary(
      uniqueKeysWithValues: templates.compactMap { guide in
        guide.softwareGuideID.map { ($0, guide) }
      }
    )
    let introducedVersionsByID = Dictionary(
      uniqueKeysWithValues: sampleTemplates(
        preferredLanguage: preferredLanguage
      ).map { ($0.id, $0.introducedInVersion) }
    )

    var refreshedGuideCount = 0
    var synchronizedDrafts = existingDrafts.map { draft in
      guard let guideID = draft.softwareGuideID,
        let template = templatesByID[guideID],
        shouldRefreshSoftwareGuide(draft)
      else {
        return draft
      }

      refreshedGuideCount += 1
      return refreshedSoftwareGuide(draft, from: template)
    }

    let installedGuideIDs = Set(synchronizedDrafts.compactMap(\.softwareGuideID))
    let eligibleMissingTemplates = templates.filter { guide in
      guard let guideID = guide.softwareGuideID,
        !installedGuideIDs.contains(guideID)
      else {
        return false
      }
      if restorePreviouslyRemovedGuides || previousSeedVersion == 0 {
        return true
      }
      return (introducedVersionsByID[guideID] ?? currentSoftwareGuideSeedVersion)
        > previousSeedVersion
    }
    let missingGuides = missingSoftwareGuides(
      in: synchronizedDrafts,
      profile: profile,
      preferredLanguage: preferredLanguage,
      now: now
    ).filter { missingGuide in
      eligibleMissingTemplates.contains {
        $0.softwareGuideID == missingGuide.softwareGuideID
      }
    }
    synchronizedDrafts.insert(contentsOf: missingGuides, at: 0)
    synchronizedDrafts = orderedSoftwareGuides(
      in: synchronizedDrafts,
      templates: templates
    )

    return SoftwareGuideSynchronizationResult(
      drafts: synchronizedDrafts,
      addedGuideCount: missingGuides.count,
      refreshedGuideCount: refreshedGuideCount
    )
  }

  private static func shouldRefreshSoftwareGuide(_ draft: ArticleDraft) -> Bool {
    guard draft.draft,
      draft.status == .draft,
      draft.repositoryPath == nil,
      draft.repositorySHA == nil
    else {
      return false
    }

    if let version = draft.softwareGuideTemplateVersion {
      return version > 0 && version < currentSoftwareGuideSeedVersion
    }
    return draft.updatedAt == draft.createdAt
  }

  private static func refreshedSoftwareGuide(
    _ existing: ArticleDraft,
    from template: ArticleDraft
  ) -> ArticleDraft {
    var refreshed = existing
    refreshed.title = template.title
    refreshed.tags = template.tags
    refreshed.categories = template.categories
    refreshed.authors = template.authors
    refreshed.summary = template.summary
    refreshed.bodyMarkdown = template.bodyMarkdown
    refreshed.assignToGeneralDraft(editingProfileID: template.siteProfileID)
    refreshed.softwareGuideTemplateVersion = currentSoftwareGuideSeedVersion
    refreshed.markUpdated(replacing: existing)
    return refreshed
  }

  private static func orderedSoftwareGuides(
    in drafts: [ArticleDraft],
    templates: [ArticleDraft]
  ) -> [ArticleDraft] {
    var orderedGuideDraftIDs: Set<UUID> = []
    let orderedGuides = templates.compactMap { template -> ArticleDraft? in
      guard let guideID = template.softwareGuideID,
        let guide = drafts.first(where: { $0.softwareGuideID == guideID })
      else {
        return nil
      }
      orderedGuideDraftIDs.insert(guide.id)
      return guide
    }
    return orderedGuides
      + drafts.filter {
        !orderedGuideDraftIDs.contains($0.id)
      }
  }

  private struct SampleTemplate {
    let id: String
    let introducedInVersion: Int
    let title: String
    let slug: String
    let tags: [String]
    let categories: [String]
    let summary: String
    let bodyMarkdown: String
  }

  private static func sampleTemplates(preferredLanguage: String?) -> [SampleTemplate] {
    let language = preferredLanguage?.lowercased() ?? "zh-hans"
    return language.hasPrefix("en") ? englishSampleTemplates : chineseSampleTemplates
  }

  private static let chineseSampleTemplates: [SampleTemplate] = [
    SampleTemplate(
      id: "getting-started",
      introducedInVersion: 1,
      title: "开始使用：认识发布工作台",
      slug: "personal-site-publisher-getting-started",
      tags: ["使用指南", "入门"],
      categories: ["指南"],
      summary: "认识顶部状态区、工作区导航、文章范围和检查器，并按推荐顺序完成第一次安全发布。",
      bodyMarkdown: """
        # 开始使用：认识发布工作台

        欢迎使用 RepoPress Studio。你正在阅读的“使用指南”默认位于通用草稿（General Drafts），不会自动发布，也没有仓库写入路径。可以直接阅读、复制，或移到回收站；如果准备改写成自己的操作手册，建议先复制一份。

        ## 顶部：先看站点、状态和入口

        - **站点切换与本地预览**：确认正在编辑哪个网站，并打开本地预览。
        - **发布状态**：汇总仓库、当前文章和部署状态；点击后可进入对应页面或打开发布流程。
        - **全局搜索（⌘P）**：搜索草稿、标签和应用指令。
        - **直接操作按钮**：常用功能直接显示；在“写作”中可打开 AI 助手或右侧检查器。

        ## 左侧：按任务切换工作区

        主工作区包含“写作、资料库、RSS 阅读、站点、检查”。“建站”和“图片”是站点相关入口；“站点维护”位于“检查”，“发布记录”位于“站点”。中央区域随任务显示编辑器、资料阅读、仓库差异或检查结果；右侧检查器显示当前任务的元数据与操作。窗口较窄或进入专注模式时，侧栏和检查器可能自动收起。

        写作列表上方有两个范围：

        - **当前站点（Current Site）**：属于当前网站，可进入检查和发布。
        - **通用草稿（General Drafts）**：跨站点复用，不直接绑定仓库；需要时再转到某个站点。

        ## 推荐的第一次使用顺序

        1. 已有网站时，在“站点”选择本地仓库，并确认站点类型、分支、文章目录和图片目录。
        2. 还没有网站时，在“站点”打开“建站”，选择模板并先审阅文件预览。
        3. 回到“写作”，新建或导入文章，补全标题、摘要、slug、标签和分类。
        4. 在“检查”修复阻断问题，然后打开顶部“发布状态”。
        5. 在发布抽屉先选择“审阅并发布所有文件…”，核对 Git 工作区的完整文件清单；只需发布当前文章、本地保存或预览分支时，展开“其他发布方式”。
        6. 发布后到“站点 → 发布记录”核对提交、PR/MR、自动化任务和部署结果。

        > 安全练习：修改本段文字，打开右侧检查器，确认归属仍显示“通用草稿，不属于站点”。这篇使用指南不会因编辑而写入站点仓库。
        """
    ),
    SampleTemplate(
      id: "writing-preview",
      introducedInVersion: 1,
      title: "写作与预览：完成第一篇文章",
      slug: "personal-site-publisher-writing-preview",
      tags: ["使用指南", "Markdown", "写作"],
      categories: ["指南"],
      summary: "选择文章范围，新建 Markdown 草稿，补全元数据，并通过预览、检查与版本记录完成一篇文章。",
      bodyMarkdown: """
        # 写作与预览：完成第一篇文章

        ## 1. 先选文章范围

        列表上方的范围用于浏览“当前站点”和“通用草稿”。新建时点击 **＋**，再明确选择“新建站点文章”或“新建通用草稿”：站点文章可进入发布流程，通用草稿适合跨网站积累提纲和素材。

        先填写清晰标题，再检查自动生成的 slug。slug 会成为文章路径的一部分，发布后尽量不要频繁修改。

        ## 2. 编辑与真实预览

        使用中央 Markdown 编辑器完成正文、查找替换、常用格式、表格、链接和图片编辑。站点文章需要检查最终渲染时，通过顶部“本地预览”打开真实站点页面。通用草稿没有仓库路径，需先将副本加入站点，再做站点预览。

        ## 3. 补全发布信息

        在右侧检查器完成摘要、日期、作者、标签、分类、公开范围和封面。摘要应能独立说明文章价值，标签和分类应少而稳定；图片需要可理解的 alt 文本。

        ## 4. 处理提示再发布

        编辑过程中可查看行内诊断、文章大纲和写作统计。完成后打开“检查”，先修复阻断问题，再决定保留草稿或标记为“待发布”。

        RepoPress Studio 会自动保存工作台。重要改动可在版本历史中比较和恢复；误删文章先到回收站查找。

        > 小练习：复制这一段，插入一个二级标题、一条链接和一个代码块；需要检查真实页面时，先将副本加入站点，再打开本地预览。
        """
    ),
    SampleTemplate(
      id: "ai-assistant",
      introducedInVersion: 2,
      title: "AI 助手：配置模型与管理多个对话",
      slug: "personal-site-publisher-ai-assistant",
      tags: ["使用指南", "AI", "写作"],
      categories: ["指南"],
      summary: "通过 ChatGPT 登录、本地模型或自带 API Key 使用 AI，并管理多个可分支、可归档的对话。",
      bodyMarkdown: """
        # AI 助手：配置模型与管理多个对话

        RepoPress Studio 支持 ChatGPT 登录、本地模型和自带 API Key 三种连接方式。远程服务的可用性、用量与费用由对应服务商和你的账户决定。

        ## 1. 配置服务商

        打开“设置 → AI → 连接”，选择“ChatGPT 登录”、“本地模型”或“API Key”。API Key 可按你的选择保存到 macOS 系统钥匙串、受限本地配置或仅本次会话，不会写入文章或仓库。

        完成登录或保存当前连接所需的凭据后，查看连接状态并执行可用的连接测试。只有理解将发送的上下文后，再确认 AI 数据共享授权。资料库中“允许发送给远程 AI”是默认关闭的逐条权限；只有资料权限与总授权同时满足时，相关片段才会发送。不要把密码、私钥或未公开客户资料发送给第三方模型。

        ## 2. 在写作页选择上下文和模型

        点击顶部 AI 助手按钮打开右侧面板：

        - 先选择“当前文章”或“通用聊天”，明确本次对话的上下文范围。
        - 再使用对话导航切换历史、新建对话，或管理当前对话。
        - 在配置区选择连接和模型；“快速、标准、高质量”会映射到当前服务商的模型，“自定义”可输入具体模型名。

        “当前文章”会结合所选文章回答；“通用聊天”适合不依赖正文的问题。发送前仍应确认上下文范围。

        ## 3. 管理多个对话

        每篇文章可保留多个独立对话。点击对话标题后可以切换、重命名、归档、恢复或删除；在任意消息的菜单中选择“从这条消息处分支对话”，可以保留原讨论并探索另一种写法。

        ## 4. 安全应用结果

        快捷操作可用于润色、摘要、标题、标签、SEO 和检查。AI 返回内容后，优先使用“预览并追加”或 Diff 预览，确认变化后再写入正文；资料库引用应打开原文核对，远程模型只会收到已明确允许发送的资料。自动化计划需要逐步确认，并在执行前查看可回滚范围。

        > AI 输出可能不准确。事实、日期、引用、链接和发布风险仍由你最终核对。
        """
    ),
    SampleTemplate(
      id: "knowledge-library",
      introducedInVersion: 1,
      title: "资料库：整理并引用长期资料",
      slug: "personal-site-publisher-knowledge-library",
      tags: ["使用指南", "资料库", "研究"],
      categories: ["指南"],
      summary: "导入本地文档或通过 Chrome、Firefox 保存网页，建立可搜索、可引用且保留来源的长期资料库。",
      bodyMarkdown: """
        # 资料库：整理并引用长期资料

        资料库适合保存研究材料、参考文档和长期笔记。它与文章草稿分开管理，因此你可以先整理来源，再决定哪些内容值得写进文章。

        ## 导入本地资料

        1. 在“资料库”选择导入入口，添加受支持的本地文档。
        2. 导入前核对标题和来源；网页和出版物应确认版权与引用范围。
        3. 导入后检查章节划分、正文识别和元数据，扫描型 PDF 可按需要使用 OCR。
        4. 使用标签、注释和收藏把资料整理为以后仍能理解的结构。

        ## 从浏览器保存网页

        打开“浏览器资料采集”查看本机连接和令牌。当前版本支持 Chrome 与 Firefox。macOS 应用不内嵌浏览器扩展，两个扩展都需要单独安装：

        - **Chrome 扩展**不包含在 App 包内，需要从 Chrome 网上应用店单独安装和更新。
        - **Firefox 扩展**不包含在 App 包内，从 `about:debugging` 临时加载 `BrowserExtension/Firefox/manifest.json`。

        扩展只连接 `127.0.0.1` 本机地址，并使用随机令牌验证。令牌只粘贴到你安装的扩展中，不要放到网页、文章或截图。Chrome 优先保存自包含 MHTML；Firefox 在大小上限内保存离线 HTML。应用暂时关闭时，扩展会在浏览器本地排队并稍后重试。

        ## 搜索与引用

        先用全文搜索定位原文，再查看关联章节或本地语义结果。把内容带入文章时，优先插入短引用、来源名称和链接，不要复制整篇原文。

        AI 助手可以基于选中资料总结或拟定提纲，并显示资料库引用；仍应打开原文核对事实、日期和上下文。资料需先固定到 AI；使用远程模型时，还必须逐条开启“允许发送给远程 AI”。

        ## 保持资料库可靠

        - 为重要资料保留明确来源。
        - 定期处理重复、失效或解析不完整的条目。
        - 批量整理或恢复之前先创建资料库备份。
        - 不要把账号令牌、私人密钥或敏感客户资料导入普通资料库。
        """
    ),
    SampleTemplate(
      id: "rss-reading",
      introducedInVersion: 5,
      title: "RSS 阅读：从订阅到灵感草稿",
      slug: "personal-site-publisher-rss-reading",
      tags: ["使用指南", "RSS", "阅读"],
      categories: ["指南"],
      summary: "添加或导入订阅，筛选与阅读全文，按明确权限翻译，并把可信来源保存到资料库或转成通用灵感草稿。",
      bodyMarkdown: """
        # RSS 阅读：从订阅到灵感草稿

        “RSS 阅读”把订阅、资料库和写作连接起来。订阅内容、阅读状态和批注默认保存在本机，仅仅阅读不会上传到第三方服务；加载远程图片、提取网页全文或使用远程 AI 翻译时，仍会连接相应的外部服务。

        ## 1. 添加或迁移订阅

        打开“RSS 阅读”，点击订阅栏的 **＋**。可以直接输入 RSS / Atom 地址，也可以粘贴博客首页并选择“发现并添加”；发现多个 Feed 时，先核对地址，再添加需要的订阅。

        已有订阅列表时，到“设置 → RSS 阅读 → 订阅迁移”导入或导出 OPML。OPML 只包含订阅名称与地址，不包含文章缓存、已读状态、稍后阅读或批注；分享前应检查其中是否带有私人地址或访问凭证。

        ## 2. 阅读、筛选与离线全文

        左侧“全部文章、未读、稍后阅读”用于切换阅读范围，也可以按标题、正文、来源、作者、标签和日期筛选。需要保留的文章先加入“稍后阅读”，不要依赖未读状态充当收藏。

        RepoPress Studio 会保存 Feed 实际返回的摘要和正文。遇到截断内容时，可以在文章中尝试“提取全文”，或到“设置 → RSS 阅读 → 阅读默认值”配置自动全文提取；该操作会访问原网站并保存净化后的正文。全文提取可能失败，也不会绕过登录、验证码或付费墙；结果不合适时可恢复原始摘要。“加载远程图片”会连接图片所在的第三方地址，可按文章临时关闭。

        ## 3. 选择翻译方式

        在文章工具栏打开“翻译”，选择“Apple 本机翻译”或“当前 AI 服务”。Apple 本机翻译在系统支持且语言包可用时于设备端处理，不会在不可用时自动改发给 AI；当前 AI 服务会发送文章标题和正文，并受 AI 远程总闸与目的地授权约束。翻译后可在原文与译文间切换，引用前仍应回到原文核对含义。

        ## 4. 保存到资料库或用于写作

        打开“导出/联动”：

        - **保存文章摘要**：把来源明确的文章资料保存到本机资料库；批量选择时也可以一次保存多篇。
        - **摘录并添加笔记**：先缩短摘录，再写下自己的判断，避免复制整篇原文。
        - **插入当前文章**：把安全长度的摘要、摘录和来源插入当前写作文章。
        - **新建灵感草稿**：创建一篇通用草稿，并自动加入安全引用与脚注；它不会直接写入站点仓库。

        ## 5. 维护与备份

        在“设置 → RSS 阅读”管理后台刷新、离线范围、内网访问和历史清理。自动清理只处理超过期限、已读、未加入稍后阅读且没有高亮的文章；手动清理前仍应核对范围。需要完整迁移时，到“设置 → 数据管理 → 备份与导入”创建完整备份：其中包含 RSS 数据，但不包含 API Key。备份仍可能包含订阅地址、文章正文和高亮，应按敏感文件保管；OPML 导出不能替代完整备份。

        > 小练习：添加一个订阅，把一篇文章加入“稍后阅读”，再保存摘要到资料库并新建灵感草稿。回到“写作”确认新草稿位于“通用草稿”，且没有仓库路径。
        """
    ),
    SampleTemplate(
      id: "safe-publishing",
      introducedInVersion: 1,
      title: "安全发布：连接仓库、检查并提交",
      slug: "personal-site-publisher-safe-publishing",
      tags: ["使用指南", "Git", "发布"],
      categories: ["指南"],
      summary: "默认审阅并发布当前 Git 工作区全部文件；单篇发布、本地保存和预览分支保留为次级选项，确认前核对完整清单。",
      bodyMarkdown: """
        # 安全发布：连接仓库、检查并提交

        最新发布流程默认审阅当前 Git 工作区的全部待提交文件，并在一次确认后创建提交、以非强制方式推送到目标分支。文章、图片、主题、配置、脚本与删除都会纳入清单；分支、远端、同步、历史和部署管理统一放在“站点”页面。

        ## 1. 配置站点

        在“站点”或设置中确认站点类型、本地仓库、远端提供商、仓库名称、目标分支、文章目录和图片目录。访问令牌应保存到系统钥匙串，不要写进文章、仓库或截图。

        获取远端变化后，先阅读仓库状态和 Diff。若同一篇文章已经在远端更新，应先导入、合并或重新确认内容，不要直接覆盖。

        ## 2. 打开统一发布流程

        点击顶部“发布状态”并进入发布。最上方的“发布仓库全部文件”是默认操作：

        1. 核对目标 `origin/分支` 和当前扫描检测到的变更数。
        2. 点击“审阅并发布所有文件…”，打开不写入仓库的确认页。
        3. 逐项核对新增、修改、删除和重命名路径，并检查提交说明。
        4. 只有在这份完整快照正是你准备发布的范围时，才确认提交与推送。

        - 没有本机绝对路径、令牌、邮箱或其他敏感信息。
        - 每个文件与删除都是本次准备交付的内容。
        - 当前分支、目标远端和已审阅的 Diff 相互一致。
        - 提交说明能概括整批变更，而不只是当前文章。

        ## 3. 默认发布仓库全部文件

        - **发布仓库全部文件**：收集所有未忽略的工作区变更，创建一次 Git 提交，并以非强制方式推送到当前目标分支。
        - **发布到网站…**：只处理当前文章及其发布包。在确认页核对远端、目标分支和全部文件差异，再按“准备 → 推送 → 目标分支/合并 → 部署验证”跟踪进度。推送成功不等于生产站点已上线。
        - **其他发布方式**：还包含“保存到本地”、草稿预览分支和“仅发布应用管理的全部文章…”。

        如果已有暂存内容、分支与目标不一致、本地 HEAD 与远端不同步、存在冲突或敏感文件，或者确认后文件又发生变化，全文件发布会停止。推送失败时会保留已创建的本地提交；完成后到“站点 → 发布记录”核对提交、自动化任务、部署状态和最终页面。
        """
    ),
    SampleTemplate(
      id: "maintenance-recovery",
      introducedInVersion: 1,
      title: "发布之后：图片、维护与版本恢复",
      slug: "personal-site-publisher-maintenance",
      tags: ["使用指南", "图片", "维护"],
      categories: ["指南"],
      summary: "用图片管理、检查、站点维护和版本历史保持网站长期清晰、稳定、可恢复。",
      bodyMarkdown: """
        # 发布之后：图片、维护与版本恢复

        一个可靠的网站需要持续维护，而不只是完成一次发布。

        ## 图片

        “图片”用于图片资源管理和批处理；文章缺图、无效引用、过大图片等问题统一到“检查”处理。优化或转换图片前先查看影响范围和可恢复版本；不要用压缩后的临时文件覆盖唯一原图。

        ## 检查

        发布前后都可以打开“检查”，重点关注空标题、重复 slug、无效链接、缺失图片、公开风险和不完整元数据。先解决错误，再评估警告是否适用于当前文章。

        ## 日常维护

        打开“检查 → 站点维护”，生成维护报告后再审阅旧文章、标签、发布时间和站内链接。每次只处理一个边界清楚的小批次，任何计划修改都先阅读预览。

        ## 恢复与追踪

        - 使用文章版本历史比较改动，必要时恢复正文。
        - 误删文章先到回收站恢复，不要立即手动删除仓库文件。
        - 在“站点”处理分支、远端和同步，在“站点 → 发布记录”查看提交、PR/MR 和部署结果。
        - 定期备份工作台和资料库；备份验证通过后再清理旧副本。

        当你已经熟悉这些流程，可以删除这组示例文章，或把它们改成自己的发布操作手册。
        """
    ),
  ]

  private static let englishSampleTemplates: [SampleTemplate] = [
    SampleTemplate(
      id: "getting-started",
      introducedInVersion: 1,
      title: "Getting Started: Meet Your Publishing Workbench",
      slug: "personal-site-publisher-getting-started",
      tags: ["Guide", "Getting Started"],
      categories: ["Guides"],
      summary:
        "Learn the top status area, workspace navigation, draft scopes, and the recommended path to a safe first release.",
      bodyMarkdown: """
        # Getting Started: Meet Your Publishing Workbench

        Welcome to RepoPress Studio. These Guide articles live in General Drafts by default. They are never published automatically and have no repository write path. Read, duplicate, or move them to the recycle bin. If you want to turn one into your own runbook, duplicate it first.

        ## Top bar: site, status, and entry points

        - **Site switcher and local preview** confirm which site you are editing and open its local preview.
        - **Publishing status** summarizes the repository, current article, and deployment. Click it to open the relevant area or publishing flow.
        - **Global search (⌘P)** finds drafts, tags, and app commands.
        - **Direct action buttons** expose frequent tools. In Writing, open the AI Assistant or the inspector from the top bar.

        ## Left side: switch by task

        The main workspaces are Writing, Library, RSS, Site, and Checks. Site Starter and Images are site-related entry points; Site Maintenance lives under Checks, and Release History lives under Site. The center shows the editor, source reader, repository differences, or checks; the right inspector follows the current task. Sidebars may collapse in a narrow window or Focus Mode.

        Writing has two content scopes:

        - **Current Site** contains site-owned articles that can enter the publishing flow.
        - **General Drafts** contains reusable drafts that are not directly bound to a repository.

        ## A good first-use sequence

        1. For an existing site, choose its local repository in Site, then confirm the site type, branch, content path, and image path.
        2. For a new site, open Site Starter from Site, choose a template, and review the file preview before creation.
        3. Return to Writing, create or import an article, and complete its title, summary, slug, tags, and category.
        4. Resolve blocking issues in Checks, then open Publishing Status.
        5. In the publish drawer, start with **Review and Publish All Files…** and inspect the complete Git worktree list. Expand **Other Publishing Options** for a single article, local save, or preview branch.
        6. Verify commits, pull or merge requests, automation, and deployment in Site → Release History.

        > Safe exercise: edit this paragraph, open the right inspector, and confirm it still says “General draft; not assigned to a site.” Editing this Guide does not write to a site repository.
        """
    ),
    SampleTemplate(
      id: "writing-preview",
      introducedInVersion: 1,
      title: "Writing and Preview: Finish Your First Article",
      slug: "personal-site-publisher-writing-preview",
      tags: ["Guide", "Markdown", "Writing"],
      categories: ["Guides"],
      summary:
        "Choose a draft scope, write in Markdown, complete metadata, and use previews, checks, and versions to finish an article.",
      bodyMarkdown: """
        # Writing and Preview: Finish Your First Article

        ## 1. Choose the draft scope

        The scope above the list browses Current Site and General Drafts. To create content, click **＋**, then explicitly choose New Site Article or New General Draft. Site articles can enter publishing; general drafts are reusable outlines and material shared across sites.

        Start with a clear title, then review the generated slug. The slug becomes part of the article path, so avoid changing it frequently after publication.

        ## 2. Edit and preview the real site

        Use the central Markdown editor for body text, find and replace, common formatting, tables, links, and images. When a site article needs final rendering checks, use Local Preview in the top bar to open the real site page. A general draft has no repository path; add a copy to a site before using site preview.

        ## 3. Complete publishing metadata

        Use the inspector to fill in the summary, date, author, tags, category, visibility, and cover. A summary should explain the article on its own, labels should remain consistent, and images need meaningful alt text.

        ## 4. Resolve feedback before release

        Use inline diagnostics, the outline, and writing statistics. When ready, open Checks, fix blocking issues, and then keep the article as a draft or mark it Ready.

        RepoPress Studio autosaves the workbench. Compare and restore important revisions in version history, and check the recycle bin before treating an accidental deletion as permanent.

        > Exercise: duplicate this paragraph and add a level-two heading, a link, and a code block. To inspect the real page, add the copy to a site and open Local Preview.
        """
    ),
    SampleTemplate(
      id: "ai-assistant",
      introducedInVersion: 2,
      title: "AI Assistant: Choose Models and Manage Conversations",
      slug: "personal-site-publisher-ai-assistant",
      tags: ["Guide", "AI", "Writing"],
      categories: ["Guides"],
      summary:
        "Connect with ChatGPT sign-in, a local model, or your own API key; choose article or general context and manage multiple conversations.",
      bodyMarkdown: """
        # AI Assistant: Choose Models and Manage Conversations

        RepoPress Studio supports ChatGPT sign-in, local models, and bring-your-own API keys. Availability, usage, and billing for remote services are determined by the provider and your account.

        ## 1. Configure a provider

        Open Settings → AI → Connection, then choose ChatGPT Sign-In, Local Model, or API Key. API keys can use macOS Keychain, a restricted local configuration file, or this session only. They are never written into an article or repository.

        Complete sign-in or save the credentials required by the selected connection, then check its status and run any available connection test. Grant AI data-sharing consent only after you understand which context will be sent. Allow Sending to Remote AI is a separate, per-item Library permission that is off by default; a source fragment is sent only when both that permission and the overall consent allow it. Never send passwords, private keys, or unreleased client material to a third-party model.

        ## 2. Choose context and model while writing

        Open the AI Assistant from the top bar:

        - First choose Current Article or General Chat so the context boundary is explicit.
        - Use conversation navigation to switch history, start a conversation, or manage the current one.
        - In configuration, choose the connection and model. Fast, Standard, and High Quality map to provider-specific models; Custom accepts an exact model name.

        Current Article uses the selected article as context. General Chat is for questions that do not depend on its body. Always confirm the context before sending.

        ## 3. Manage multiple conversations

        Each article can keep several independent conversations. Open the conversation title to switch, rename, archive, restore, or delete. Use “Branch Conversation from This Message” in a message menu to preserve the original discussion while exploring another direction.

        ## 4. Apply results safely

        Quick actions cover rewriting, summaries, titles, tags, SEO, and checks. Prefer Preview and Append or a Diff preview before changing the article. Open Library citations and verify the source; a remote model receives only sources explicitly allowed for sending. Review every automation step and its rollback scope before execution.

        > AI output can be wrong. You remain responsible for facts, dates, citations, links, and publishing risks.
        """
    ),
    SampleTemplate(
      id: "knowledge-library",
      introducedInVersion: 1,
      title: "Library: Organize and Cite Long-Term Sources",
      slug: "personal-site-publisher-knowledge-library",
      tags: ["Guide", "Library", "Research"],
      categories: ["Guides"],
      summary:
        "Import local documents or save pages from Chrome and Firefox to build a searchable, citable library with clear provenance.",
      bodyMarkdown: """
        # Library: Organize and Cite Long-Term Sources

        The Library is for research material, reference documents, and long-lived notes. It is separate from article drafts, so you can organize evidence before deciding what belongs in a post.

        ## Import local material

        1. In Library, use the import entry point to add a supported local document.
        2. Review its title and source before import, and respect copyright and quotation limits.
        3. After import, inspect chapter boundaries, extracted text, and metadata. Use OCR only when a scanned PDF needs it.
        4. Add tags, annotations, and favorites that will still make sense months later.

        ## Save pages from a browser

        Open Browser Capture to see the local connection and token. This release supports Chrome and Firefox. The macOS app contains no embedded browser extension, so install both extensions separately:

        - The **Chrome extension is not included in the app bundle**. Install and update it separately through the Chrome Web Store.
        - The **Firefox extension is not included in the app bundle**. Load `BrowserExtension/Firefox/manifest.json` temporarily from `about:debugging`.

        Extensions connect only to `127.0.0.1` and authenticate with a random token. Paste that token only into your installed extension—never into a webpage, article, or screenshot. Chrome prefers self-contained MHTML; Firefox saves offline HTML within its size limit. If RepoPress Studio is closed, the extension queues the item locally and retries later.

        ## Search and cite

        Begin with full-text search, then inspect related chapters or local semantic results. Prefer a short quotation, source name, and link instead of copying an entire document.

        The AI Assistant can summarize selected material or draft an outline with Library citations. Open the source and verify facts, dates, and context. Pin a source to AI first; when using a remote model, also enable its per-item Allow Sending to Remote AI permission.

        ## Keep the library reliable

        - Preserve a clear source for important material.
        - Review duplicates, broken sources, and incomplete extraction regularly.
        - Create a library backup before large cleanup or restore operations.
        - Never import account tokens, private keys, or sensitive client material into a normal library.
        """
    ),
    SampleTemplate(
      id: "rss-reading",
      introducedInVersion: 5,
      title: "RSS Reader: From Subscriptions to Idea Drafts",
      slug: "personal-site-publisher-rss-reading",
      tags: ["Guide", "RSS", "Reading"],
      categories: ["Guides"],
      summary:
        "Add or import feeds, filter and read full text, translate with explicit permissions, and save trusted sources to Library or general idea drafts.",
      bodyMarkdown: """
        # RSS Reader: From Subscriptions to Idea Drafts

        RSS Reader connects subscriptions, Library, and Writing. Subscription content, reading state, and annotations are stored locally by default, and reading alone does not upload them to a third party. Loading remote images, extracting full text from a webpage, or using remote AI translation still connects to the relevant external service.

        ## 1. Add or migrate subscriptions

        Open RSS Reader and click **＋** in the subscription sidebar. Enter an RSS or Atom URL directly, or paste a blog homepage and choose **Discover and Add**. When several feeds are found, verify their URLs before adding the ones you need.

        For an existing subscription list, use Settings → RSS Reader → Subscription Migration to import or export OPML. OPML contains only subscription names and addresses—not cached articles, read state, Read Later items, or annotations. Before sharing it, check for private addresses or embedded access credentials.

        ## 2. Read, filter, and keep full text offline

        Use All Articles, Unread, and Read Later to switch reading scopes, then filter by title, body, source, author, tag, or date. Put material you want to keep in Read Later instead of treating unread state as a bookmark.

        RepoPress Studio stores the summary and body actually returned by the feed. For truncated content, try **Fetch Full Text** from the article or configure automatic full-text extraction in Settings → RSS Reader → Reading Defaults. This visits the original site and stores a sanitized body. Extraction can fail and does not bypass sign-in, CAPTCHAs, or paywalls; use **Show Original Summary** when the result is not suitable. **Load Remote Images** connects to third-party image hosts and can be disabled for an article.

        ## 3. Choose a translation method

        Open **Translate** in the article toolbar and choose **Apple On-Device Translation** or **Current AI Service**. Apple translation stays on device when the system supports it and the language pack is available; it does not silently fall back to AI when unavailable. Current AI Service sends the article title and body, subject to the global remote-AI gate and destination authorization. You can switch between original and translated text; verify the original before quoting it.

        ## 4. Save to Library or use in Writing

        Open **Export / Integrations**:

        - **Save Article Summary** stores a source-linked article record in the local Library. Batch selection can save several articles at once.
        - **Excerpt and Add Note** lets you shorten the quotation and record your own analysis instead of copying the full source.
        - **Insert Current Article** adds a safely bounded summary, excerpt, and source to the current writing draft.
        - **New Idea Draft** creates a General Draft with a safe citation and footnote. It does not write directly to a site repository.

        ## 5. Maintain and back up RSS data

        Use Settings → RSS Reader for background refresh, offline scope, private-network access, and history cleanup. Automatic cleanup affects only old articles that are read, not in Read Later, and have no highlights; still review the scope before manual cleanup. For a complete migration, use Settings → Data Management → Backup and Import to create a full backup. It includes RSS data but excludes API keys. The backup may still contain subscription URLs, article bodies, and highlights, so handle it as a sensitive file; an OPML export does not replace a full backup.

        > Exercise: add one subscription, put an article in Read Later, save its summary to Library, and create an idea draft. Return to Writing and confirm the new item is in General Drafts with no repository path.
        """
    ),
    SampleTemplate(
      id: "safe-publishing",
      introducedInVersion: 1,
      title: "Safe Publishing: Connect, Review, and Commit",
      slug: "personal-site-publisher-safe-publishing",
      tags: ["Guide", "Git", "Publishing"],
      categories: ["Guides"],
      summary:
        "Review and publish every pending Git worktree file by default; keep single-article publishing, local save, and preview branches as secondary choices, and verify the complete file list before confirmation.",
      bodyMarkdown: """
        # Safe Publishing: Connect, Review, and Commit

        The default publishing flow reviews every pending Git worktree file and, after one confirmation, creates one commit and pushes it without force to the target branch. Articles, images, themes, configuration, scripts, and deletions are all included. Branch, remote, synchronization, history, and deployment management live in Site.

        ## 1. Configure the site

        In Site or Settings, confirm the site type, local repository, remote provider, repository name, target branch, content path, and image path. Store access tokens in the system Keychain—never in an article, repository, or screenshot.

        Fetch remote changes and read the repository status and Diff. If the same article changed upstream, import, merge, or review it again instead of overwriting it.

        ## 2. Open the unified publishing flow

        Click **Publishing Status** in the top bar and open Publish. **Publish All Repository Files** is the default action at the top of the drawer:

        1. Confirm the target `origin/branch` and the number of changes found by the current scan.
        2. Select **Review and Publish All Files…** to open a confirmation page that does not write to the repository.
        3. Review every added, modified, deleted, and renamed path, then check the commit message.
        4. Confirm the commit and push only when this complete snapshot is exactly the scope you intend to publish.

        - No local absolute path, token, email address, or sensitive value is exposed.
        - Every file and deletion belongs in this delivery.
        - The current branch, target remote, and reviewed Diff agree.
        - The commit message describes the entire batch, not only the selected article.

        ## 3. Publish all repository files by default

        - **Publish All Repository Files** collects every unignored worktree change, creates one Git commit, and pushes it without force to the current target branch.
        - **Publish to Website…** handles only the current article and its release package. Verify the remote, target branch, and every file diff, then follow Prepare → Push → Target Branch/Merge → Deployment Verification. A successful push is not proof that production is live.
        - **Other Publishing Options** also contains **Save Locally**, the draft preview branch, and **Publish All App-Managed Articles Only…**.

        Publishing stops if the index already contains staged files, the branch or remote is out of sync, conflicts or sensitive paths are present, or files change after confirmation. If the push fails, the newly created local commit is retained. After success, use Site → Release History to verify the commit, automation, deployment, and final page.
        """
    ),
    SampleTemplate(
      id: "maintenance-recovery",
      introducedInVersion: 1,
      title: "After Publishing: Images, Maintenance, and Recovery",
      slug: "personal-site-publisher-maintenance",
      tags: ["Guide", "Images", "Maintenance"],
      categories: ["Guides"],
      summary:
        "Use image management, Checks, Site Maintenance, and version history to keep the site clear and recoverable.",
      bodyMarkdown: """
        # After Publishing: Images, Maintenance, and Recovery

        A dependable site needs ongoing care, not just a successful first release.

        ## Images

        Images handles resource management and batch operations. Use Checks for missing images, broken references, oversized images, and other article-level issues. Review the affected scope and a recoverable version before optimization or conversion, and never replace your only original with a temporary compressed copy.

        ## Checks

        Open Checks before and after release. Pay particular attention to empty titles, duplicate slugs, broken links, missing images, public-exposure risks, and incomplete metadata. Fix errors first, then decide whether each warning applies.

        ## Routine maintenance

        Open Checks → Site Maintenance and generate a report before reviewing older posts, tags, publishing dates, and internal links. Work in small, clearly scoped batches and preview every planned change before writing.

        ## Recovery and traceability

        - Compare article versions and restore content when necessary.
        - Recover accidental deletions from the recycle bin before touching repository files manually.
        - Manage branches, remotes, and synchronization in Site; inspect commits, pull/merge requests, and deployments in Site → Release History.
        - Back up the workbench and Library regularly, and verify a backup before deleting older copies.

        Once these workflows feel familiar, delete the sample articles or adapt them into your own publishing runbook.
        """
    ),
  ]
}
