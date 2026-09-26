# RepoPress Share Extension

该 target 将 macOS Share Sheet 收到的 HTTPS 网页链接、文本，以及 PDF、Markdown、文本、HTML 或图片文件放入 App Group 收件箱。它不直接改写资料库；宿主应用在启动、激活或收到 `com.jinfang.repopress.intake.ready` 分布式通知后负责验证并导入。成功状态仅表示已交给 RepoPress、等待导入；如主应用没有运行，用户打开 RepoPress 后会继续处理。

## 暂存契约

扩展在 `3H8UVVUCP3.com.jinfang.repopress.intake/Inbox` 下为每项内容建立 `.<UUID>.pending`，写入文件和 `manifest.json` 后再原子移动为 `<UUID>`。主应用应忽略隐藏目录，只处理已完成的目录。

`manifest.json` 固定包含 `version: 1`、`kind`（`webURL`、`file` 或 `note`）及 ISO 8601 `createdAt`。网页使用 `url` 和可选 `title`；笔记使用 `text` 和可选 `title`；文件使用用户可读的 `fileName` 与实际暂存文件名 `storedFileName`。普通文件保存在同一目录的 `payload.<ext>`，上限为 50 MiB；图片仅接受 JPEG、PNG、HEIC、HEIF 和 WebP，且上限为 25 MiB；笔记 UTF-8 内容上限为 1 MiB。超限内容在暂存前拒绝。

## 集成

将 `RepoPressShareExtension.appex` 嵌入主应用的 `Contents/PlugIns/`，并让主应用和扩展的签名 profile 都包含 App Group `3H8UVVUCP3.com.jinfang.repopress.intake`。宿主负责在启动和激活时扫描 `Inbox`，以覆盖扩展运行时宿主未启动的情况。

无签名构建：

```bash
xcodebuild -project ShareExtension/RepoPressShareExtension.xcodeproj -scheme RepoPressShareExtension -configuration Debug -derivedDataPath ShareExtension/.DerivedData CODE_SIGNING_ALLOWED=NO build
```

Debug 产物位于 `ShareExtension/.DerivedData/Build/Products/Debug/RepoPressShareExtension.appex`。
