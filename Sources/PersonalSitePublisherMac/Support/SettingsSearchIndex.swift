import Foundation

struct SettingsSearchItem: Identifiable, Hashable, Sendable {
  let id: String
  let tab: SettingsTab
  let sectionTitle: String
  let destination: SettingsDestination?
  let keywords: [String]
  let detail: String
  let systemImage: String

  func matches(query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }
    let pool = [sectionTitle, detail, tab.title] + keywords
    let combined = pool.joined(separator: " ")
    return combined.range(of: normalized, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}

enum SettingsSearchIndex {
  static let allItems: [SettingsSearchItem] = [
    // 站点概览
    SettingsSearchItem(
      id: "status.repo",
      tab: .configurationStatus,
      sectionTitle: String(localized: "本地仓库与发布就绪状态"),
      destination: .tab(.configurationStatus),
      keywords: ["Git", "仓库路径", "就绪", "检查", "发布目标", "overview", "status"],
      detail: String(localized: "查看本地仓库路径、发布规则完整性与当前发布目标。"),
      systemImage: "checkmark.seal"
    ),
    SettingsSearchItem(
      id: "status.health",
      tab: .configurationStatus,
      sectionTitle: String(localized: "发布健康检查卡片"),
      destination: .tab(.configurationStatus),
      keywords: ["健康检查", "Front Matter 状态", "Token 状态", "AI 状态", "Preflight"],
      detail: String(localized: "排查当前站点的 Front Matter、发布 Token 和 AI 服务就绪情况。"),
      systemImage: "heart.text.square"
    ),

    // 内容与路径
    SettingsSearchItem(
      id: "rules.frontMatter",
      tab: .defaultRules,
      sectionTitle: String(localized: "Front Matter 默认元数据"),
      destination: .tab(.defaultRules),
      keywords: [
        "Front Matter", "YAML", "TOML", "自定义元数据", "作者", "分类", "标签", "Header", "头信息", "frontmatter",
        "模拟", "Front Matter 预览",
      ],
      detail: String(localized: "配置新建文章时的默认作者、预设标签、预设分类和自定义键值对。"),
      systemImage: "doc.text"
    ),
    SettingsSearchItem(
      id: "rules.paths",
      tab: .defaultRules,
      sectionTitle: String(localized: "文章与图片路径规则"),
      destination: .rules(.paths),
      keywords: [
        "路径模板", "文件名", "Slug", "图片路径", "公开图片", "日期格式", "DateFormat", "assets", "static", "pattern",
        "URL 路径", "模拟发布路径", "路由模拟",
      ],
      detail: String(localized: "设置 Markdown 文件存储路径、图片资源路径与日期占位符规则。"),
      systemImage: "slider.horizontal.3"
    ),
    SettingsSearchItem(
      id: "rules.site",
      tab: .defaultRules,
      sectionTitle: String(localized: "站点引擎与基本参数"),
      destination: .tab(.defaultRules),
      keywords: [
        "站点名称", "基础 URL", "BaseURL", "默认分支", "发布引擎", "SSG", "Hugo", "Zola", "Astro", "Jekyll",
        "Hexo", "VitePress",
      ],
      detail: String(localized: "管理站点的静态生成引擎类型、网站主域名和目标 Git 分支。"),
      systemImage: "globe"
    ),
    SettingsSearchItem(
      id: "rules.discovery",
      tab: .defaultRules,
      sectionTitle: SettingsSubsection.rulesDiscovery.title,
      destination: .tab(.defaultRules),
      keywords: ["仓库发现", "扫描内容目录", "识别结构", "Discovery"],
      detail: SettingsSubsection.rulesDiscovery.subtitle,
      systemImage: SettingsSubsection.rulesDiscovery.systemImage
    ),

    // 发布连接
    SettingsSearchItem(
      id: "token.repository",
      tab: .token,
      sectionTitle: String(localized: "代码仓库 Token 与访问凭据"),
      destination: .token(.repository),
      keywords: [
        "GitHub", "GitLab", "PAT", "Personal Access Token", "仓库权限", "推送凭据", "钥匙串", "Keychain",
        "Remote", "远端",
      ],
      detail: String(localized: "管理 GitHub / GitLab 访问令牌、检查写入权限与在线连通性。"),
      systemImage: "key.horizontal"
    ),
    SettingsSearchItem(
      id: "token.deployment",
      tab: .token,
      sectionTitle: String(localized: "部署平台自动化发布"),
      destination: .token(.deployment),
      keywords: [
        "Cloudflare Pages", "Vercel", "Netlify", "GitHub Pages", "Deploy Hook", "自动化发布", "CI/CD",
        "WebHook", "Deploy",
      ],
      detail: String(localized: "配置自动化构建触发钩子与各静态托管平台的部署令牌。"),
      systemImage: "arrow.up.icloud"
    ),
    SettingsSearchItem(
      id: "token.analytics",
      tab: .token,
      sectionTitle: String(localized: "站点阅读统计与分析"),
      destination: .token(.analytics),
      keywords: [
        "Umami", "Plausible", "Google Analytics", "阅读统计", "访问量", "PV", "UV", "Analytics", "统计 API",
      ],
      detail: String(localized: "连接私有或云端统计平台，在发布后查看文章访问与互动数据。"),
      systemImage: "chart.bar.xaxis"
    ),

    // AI 助手
    SettingsSearchItem(
      id: "ai.provider",
      tab: .ai,
      sectionTitle: String(localized: "AI 模型服务商与连接端点"),
      destination: .ai(.connection),
      keywords: [
        "Ollama", "OpenAI", "DeepSeek", "Claude", "Anthropic", "Kimi", "Moonshot",
        "GLM", "Zhipu", "Qwen", "通义千问", "Mistral", "Perplexity", "Codex", "ChatGPT",
        "自定义端点", "Base URL", "模型名称", "Model", "本地大模型", "本地 AI", "provider",
      ],
      detail: String(localized: "配置云端或本地兼容 API 端点、选择对话模型并执行连通性测试。"),
      systemImage: "sparkles"
    ),
    SettingsSearchItem(
      id: "ai.credentials",
      tab: .ai,
      sectionTitle: String(localized: "API Key 钥匙串安全存储"),
      destination: .ai(.credentials),
      keywords: ["API Key", "密钥", "Keychain", "钥匙串", "凭据存储", "Session", "临时会话", "密码", "token"],
      detail: String(localized: "设置 API Key 存储在系统钥匙串、受限本地配置还是仅本次运行保留。"),
      systemImage: "lock.shield"
    ),
    SettingsSearchItem(
      id: "ai.writingStyle",
      tab: .ai,
      sectionTitle: String(localized: "AI 写作风格与个性化设定"),
      destination: .ai(.writingStyle),
      keywords: ["写作风格", "System Prompt", "语气", "润色偏好", "审稿规则", "提示词", "Template", "style"],
      detail: String(localized: "自定义 AI 润色、审稿、起标题时的专属写作语调与排版习惯。"),
      systemImage: "wand.and.stars"
    ),
    SettingsSearchItem(
      id: "ai.advanced",
      tab: .ai,
      sectionTitle: SettingsSubsection.aiAdvanced.title,
      destination: .tab(.ai),
      keywords: ["温度", "超时", "代理", "网络", "能力检查", "参数"],
      detail: SettingsSubsection.aiAdvanced.subtitle,
      systemImage: SettingsSubsection.aiAdvanced.systemImage
    ),

    // 通用与外观
    SettingsSearchItem(
      id: "appearance.theme",
      tab: .appearance,
      sectionTitle: String(localized: "主题外观与强调色"),
      destination: .tab(.appearance),
      keywords: [
        "深色模式", "浅色模式", "Dark Mode", "Light Mode", "江南春", "主题色", "Accent Color", "外观", "高对比度",
        "theme",
      ],
      detail: String(localized: "切换工作台深浅外观模式，选择江南春或系统强调色板。"),
      systemImage: "paintpalette"
    ),
    SettingsSearchItem(
      id: "appearance.language",
      tab: .appearance,
      sectionTitle: String(localized: "应用语言与本地化"),
      destination: .tab(.appearance),
      keywords: ["语言", "Language", "简体中文", "English", "多语言", "本地化", "Locale"],
      detail: String(localized: "切换应用界面显示语言（跟随系统、简体中文或 English）。"),
      systemImage: "character.book.closed"
    ),
    SettingsSearchItem(
      id: "appearance.launch",
      tab: .appearance,
      sectionTitle: String(localized: "启动与自动扫描行为"),
      destination: .tab(.appearance),
      keywords: ["启动扫描", "自动检查", "Preflight", "自动预检", "Launch", "后台检查"],
      detail: String(localized: "控制应用启动时是否自动扫描 Git 仓库与内容健康状态。"),
      systemImage: "gearshape.arrow.triangle.2.circlepath"
    ),
    SettingsSearchItem(
      id: "appearance.extension",
      tab: .appearance,
      sectionTitle: String(localized: "浏览器采集扩展连接"),
      destination: .tab(.appearance),
      keywords: [
        "Chrome", "Firefox", "浏览器插件", "采集扩展", "127.0.0.1", "回环接口", "Loopback", "Extension Token",
        "剪藏",
      ],
      detail: String(localized: "管理 Chrome / Firefox 扩展连接令牌与本地安全接口状态。"),
      systemImage: "puzzlepiece.extension"
    ),
    SettingsSearchItem(
      id: "appearance.defaults",
      tab: .appearance,
      sectionTitle: SettingsSubsection.appearanceDefaults.title,
      destination: .tab(.appearance),
      keywords: ["新文章", "默认值", "Front Matter", "全局预设"],
      detail: SettingsSubsection.appearanceDefaults.subtitle,
      systemImage: SettingsSubsection.appearanceDefaults.systemImage
    ),

    // 编辑器
    SettingsSearchItem(
      id: "editor.typography",
      tab: .editor,
      sectionTitle: String(localized: "排版与字号行距"),
      destination: .tab(.editor),
      keywords: [
        "字号", "行距", "行高", "正文最大宽度", "编辑器宽度", "字体", "等宽字体", "Font Size", "Line Spacing",
        "typography",
      ],
      detail: String(localized: "调整 Markdown 编辑区正文字号、行距倍数与文本舒适阅读宽度。"),
      systemImage: "textformat.size"
    ),
    SettingsSearchItem(
      id: "editor.comfort",
      tab: .editor,
      sectionTitle: String(localized: "打字机模式与沉浸写作"),
      destination: .tab(.editor),
      keywords: ["打字机模式", "Typewriter", "段落聚光灯", "光标居中", "纸张背景", "Zen Mode", "专注模式", "高亮当前段落"],
      detail: String(localized: "启用打字机垂直居中滚动、当前段落聚光灯以及极简专注界面。"),
      systemImage: "text.aligncenter"
    ),
    SettingsSearchItem(
      id: "editor.tools",
      tab: .editor,
      sectionTitle: String(localized: "工具栏定制与排版自动化"),
      destination: .tab(.editor),
      keywords: ["格式工具栏", "工具栏定制", "气泡工具栏", "自动配对", "中英文空格", "排版净化", "字数统计", "快捷键", "Toolbar"],
      detail: String(localized: "自定义顶部格式栏按钮、括号符号自动闭合与中英文排版规范。"),
      systemImage: "wrench.and.screwdriver"
    ),
    SettingsSearchItem(
      id: "editor.preview",
      tab: .editor,
      sectionTitle: SettingsSubsection.editorPreview.title,
      destination: .tab(.editor),
      keywords: ["效果预览", "排版预览", "阅读效果", "Preview"],
      detail: SettingsSubsection.editorPreview.subtitle,
      systemImage: SettingsSubsection.editorPreview.systemImage
    ),

    // RSS 阅读
    SettingsSearchItem(
      id: "rss.storage",
      tab: .rss,
      sectionTitle: String(localized: "RSS 离线缓存与全文提取"),
      destination: .tab(.rss),
      keywords: ["离线阅读", "自动提取全文", "Readability", "远程图片", "图片离线", "本地缓存", "Offline", "抓取全文"],
      detail: String(localized: "控制刷新时是否自动提取截断正文以及文章图片的离线缓存。"),
      systemImage: "arrow.down.doc"
    ),
    SettingsSearchItem(
      id: "rss.opml",
      tab: .rss,
      sectionTitle: String(localized: "OPML 订阅导入与备份"),
      destination: .tab(.rss),
      keywords: ["OPML", "导入订阅", "导出订阅", "备份订阅", "Feed 列表", "Inoreader", "Feedly", "RSS 导入"],
      detail: String(localized: "导入外部阅读器的 OPML 订阅列表或导出本机所有订阅源备份。"),
      systemImage: "arrow.left.arrow.right"
    ),
    SettingsSearchItem(
      id: "rss.translation",
      tab: .rss,
      sectionTitle: String(localized: "RSS 自动翻译偏好"),
      destination: .tab(.rss),
      keywords: ["自动翻译", "翻译语言", "英文翻译", "中文翻译", "Translation", "Translate"],
      detail: String(localized: "设置外语 RSS 文章在打开时是否自动调用 AI 翻译并指定目标语言。"),
      systemImage: "translate"
    ),
    SettingsSearchItem(
      id: "rss.maintenance",
      tab: .rss,
      sectionTitle: String(localized: "历史文章保留与清理"),
      destination: .tab(.rss),
      keywords: ["保留天数", "已读清理", "历史文章", "定时清理", "清理缓存", "Prune", "Retention"],
      detail: String(localized: "设置已读文章的自动清理周期与数据库空间压缩。"),
      systemImage: "trash"
    ),
    SettingsSearchItem(
      id: "rss.refresh",
      tab: .rss,
      sectionTitle: SettingsSubsection.rssRefresh.title,
      destination: .tab(.rss),
      keywords: ["刷新频率", "后台刷新", "缓存", "Refresh"],
      detail: SettingsSubsection.rssRefresh.subtitle,
      systemImage: SettingsSubsection.rssRefresh.systemImage
    ),

    // 隐私与安全
    SettingsSearchItem(
      id: "privacy.quickHide",
      tab: .privacy,
      sectionTitle: String(localized: "快速隐藏与临时遮挡"),
      destination: .tab(.privacy),
      keywords: ["老板键", "Quick Hide", "快捷键", "临时遮挡", "模糊遮罩", "私密模式", "Privacy"],
      detail: String(localized: "配置快速隐藏工作区界面的全局快捷键与临时遮挡遮罩。"),
      systemImage: "eye.slash"
    ),
    SettingsSearchItem(
      id: "privacy.masking",
      tab: .privacy,
      sectionTitle: SettingsSubsection.privacyMasking.title,
      destination: .tab(.privacy),
      keywords: ["遮挡", "路径隐藏", "正文隐藏", "预览保护"],
      detail: SettingsSubsection.privacyMasking.subtitle,
      systemImage: SettingsSubsection.privacyMasking.systemImage
    ),
    SettingsSearchItem(
      id: "privacy.status",
      tab: .privacy,
      sectionTitle: SettingsSubsection.privacyStatus.title,
      destination: .tab(.privacy),
      keywords: ["保护状态", "快捷键", "安全状态"],
      detail: SettingsSubsection.privacyStatus.subtitle,
      systemImage: SettingsSubsection.privacyStatus.systemImage
    ),

    // 数据与备份
    SettingsSearchItem(
      id: "data.storage",
      tab: .dataManagement,
      sectionTitle: String(localized: "存储管理与图片瘦身 (WebP / JPEG)"),
      destination: .tab(.dataManagement),
      keywords: [
        "存储占用", "WebP", "图片压缩", "瘦身", "JPEG 压缩", "清理缓存", "临时文件", "孤立资源", "Storage", "Compress",
      ],
      detail: String(localized: "查看工作台数据占用、执行全库图片无损/有损瘦身与孤立附件清理。"),
      systemImage: "photo.stack"
    ),
    SettingsSearchItem(
      id: "data.drafts",
      tab: .dataManagement,
      sectionTitle: String(localized: "草稿版本历史与回收站"),
      destination: .data(.drafts),
      keywords: ["草稿生命周期", "版本快照", "版本历史", "自动保存版本", "回收站", "永久删除", "恢复草稿", "Versions", "Trash"],
      detail: String(localized: "管理本地草稿的历史版本保留数量、回收站与废纸篓恢复。"),
      systemImage: "clock.arrow.circlepath"
    ),
    SettingsSearchItem(
      id: "data.backup",
      tab: .dataManagement,
      sectionTitle: String(localized: "工作区完整备份与恢复"),
      destination: .data(.backup),
      keywords: ["工作区备份", "导出备份", "恢复工作区", "Zip 备份", "灾备", "迁移", "Backup", "Restore"],
      detail: String(localized: "导出包含文章、素材和配置的完整工作区归档，或从已有备份还原。"),
      systemImage: "archivebox"
    ),
    SettingsSearchItem(
      id: "data.migration",
      tab: .dataManagement,
      sectionTitle: String(localized: "外部站点内容迁移助手"),
      destination: .data(.migration),
      keywords: [
        "内容迁移", "WordPress 导入", "Ghost 导入", "Notion 导入", "Hexo 迁移", "Markdown 批量迁移", "Migration",
        "Import",
      ],
      detail: String(localized: "从 WordPress、Ghost、Notion 或其他 Markdown 目录批量导入文章与素材。"),
      systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard"
    ),
  ]

  static func search(query: String) -> [SettingsSearchItem] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return allItems.filter { $0.matches(query: normalized) }
  }

  static func matchingTabs(query: String) -> Set<SettingsTab> {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return Set(SettingsTab.allCases) }
    let matchedItemTabs = Set(search(query: normalized).map(\.tab))
    let matchedDirectTabs = Set(
      SettingsTab.allCases.filter { $0.matchesSearchDirectly(normalized) })
    return matchedItemTabs.union(matchedDirectTabs)
  }
}
