# RepoPress Desktop

RepoPress Studio 的跨平台桌面原型，使用 Tauri 2、React、TypeScript 和 Rust。当前目标是在 macOS 上完成开发，同时让同一套客户端代码可以在 Ubuntu 上持续验证。

## 当前范围

- 选择本地仓库并建立受限会话
- 扫描并打开仓库内的 Markdown 文件
- CodeMirror 编辑与经过清理的 Markdown 预览
- 使用 SHA-256 基线检测外部修改，冲突时拒绝覆盖
- 原子保存，并保留 UTF-8 BOM 与 LF/CRLF 换行格式
- 只读显示 Git 分支、ahead/behind 和工作区改动

当前明确不包含站点运行时、提交、拉取、推送、远端认证和发布；浏览器开发预览也是只读演示，不能证明本地文件能力。

## 本地开发

需要 Node.js 24、npm、Rust 1.90，以及目标系统对应的 Tauri 依赖。

```bash
npm ci
npm run dev
npm run tauri dev
```

## 验证

```bash
npm test -- --run
npm run build
cargo fmt --manifest-path src-tauri/Cargo.toml --all -- --check
cargo test --manifest-path src-tauri/Cargo.toml --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets --locked -- -D warnings
```

macOS 上的通过结果只证明当前主机可构建、测试和启动。Linux 支持必须以 Ubuntu CI 或真实 Linux 设备上的同一套检查及窗口验证为准。

## 安全边界

Rust 后端只接受打开仓库后签发的 `sessionId` 和 `documentId`。Markdown 路径必须位于仓库内，绝对路径、父目录穿越、`.git`、符号链接、非 UTF-8 内容和超过 4 MiB 的文档会被拒绝。Git 状态命令不经过 shell，并设有超时和输出上限。
