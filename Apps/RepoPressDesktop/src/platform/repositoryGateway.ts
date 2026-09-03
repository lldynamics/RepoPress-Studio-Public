import { invoke } from "@tauri-apps/api/core";
import type { CapabilitySnapshot, DocumentSnapshot, GitStatusSnapshot, MarkdownFileEntry, RepositoryGateway, RepositorySessionSnapshot, SaveDocumentRequest, SaveDocumentResult } from "../contracts/repository";

type Invoke = <T>(command: string, args?: object) => Promise<T>;
const command = { capabilities: "get_capabilities", openRepository: "open_repository", listMarkdownFiles: "list_markdown_files", openDocument: "open_document", saveDocument: "save_document", gitStatus: "git_status" } as const;
export function createRepositoryGateway(tauriInvoke?: Invoke): RepositoryGateway {
  const defaultInvoke: Invoke = (name, args) => invoke(name, args as never);
  return tauriInvoke || isTauriRuntime() ? new TauriRepositoryGateway(tauriInvoke ?? defaultInvoke) : new BrowserDemoRepositoryGateway();
}
class TauriRepositoryGateway implements RepositoryGateway {
  constructor(private readonly call: Invoke) {}
  getCapabilities() { return this.call<CapabilitySnapshot>(command.capabilities); }
  openRepository(path: string) { return this.call<RepositorySessionSnapshot>(command.openRepository, { path }); }
  listMarkdownFiles(sessionId: string) { return this.call<MarkdownFileEntry[]>(command.listMarkdownFiles, { sessionId }); }
  openDocument(sessionId: string, relativePath: string) { return this.call<DocumentSnapshot>(command.openDocument, { sessionId, relativePath }); }
  saveDocument(request: SaveDocumentRequest) { return this.call<SaveDocumentResult>(command.saveDocument, request); }
  gitStatus(sessionId: string) { return this.call<GitStatusSnapshot>(command.gitStatus, { sessionId }); }
}
class BrowserDemoRepositoryGateway implements RepositoryGateway {
  async getCapabilities(): Promise<CapabilitySnapshot> { return { localEdit: false, markdownPreview: true, gitStatus: false, siteRuntime: false, gitCommit: false, gitPush: false, gitFetch: false, remoteAuth: false }; }
  async openRepository(_: string): Promise<RepositorySessionSnapshot> { return { sessionId: "demo-session", rootPath: "/演示/RepoPress", displayName: "RepoPress 演示仓库", siteKind: "演示", contentRoot: "content", isGitRepository: false, warnings: ["浏览器演示不访问本地磁盘。"] }; }
  async listMarkdownFiles(): Promise<MarkdownFileEntry[]> { return [{ relativePath: "content/欢迎.md", displayName: "欢迎.md", directory: "content", byteSize: 240 }, { relativePath: "content/编辑说明.md", displayName: "编辑说明.md", directory: "content", byteSize: 180 }]; }
  async openDocument(_: string, relativePath: string): Promise<DocumentSnapshot> { return { documentId: "demo-document", relativePath, text: "# RepoPress 桌面版\n\n这是**只读浏览器演示**。请在 Tauri 桌面应用中选择真实仓库后编辑。\n\n- 支持中文和 Emoji ✨\n- 预览会移除脚本、事件和外部资源\n- 此处不是站点构建结果\n\n[文档链接](https://example.com)", encoding: "utf-8", lineEnding: "lf", byteSize: 240, baselineSha256: "demo-read-only", revision: 1, writable: false, readOnlyReason: "浏览器演示不会写入文件。" }; }
  async saveDocument(): Promise<SaveDocumentResult> { throw { code: "read_only_demo", message: "浏览器演示不会写入文件。请在桌面应用中保存。" }; }
  async gitStatus(): Promise<GitStatusSnapshot> { return { available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: ["演示模式未读取 Git。"] }; }
}
function isTauriRuntime(): boolean { return "__TAURI_INTERNALS__" in window; }
