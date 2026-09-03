import { useEffect, useMemo, useState } from "react";
import CodeMirror from "@uiw/react-codemirror";
import { markdown } from "@codemirror/lang-markdown";
import { oneDark } from "@codemirror/theme-one-dark";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { type DocumentSnapshot, type GitStatusSnapshot, type MarkdownFileEntry, type RepositorySessionSnapshot } from "./contracts/repository";
import { createRepositoryGateway } from "./platform/repositoryGateway";
import { renderMarkdownPreview } from "./preview/renderMarkdownPreview";
import "./App.css";

type EditorState = "clean" | "dirty" | "saving" | "saved" | "conflict" | "failed";
const gateway = createRepositoryGateway();

function editorStateLabel(state: EditorState): string {
  return { clean: "已保存", dirty: "有未保存修改", saving: "正在保存…", saved: "刚刚保存", conflict: "保存冲突", failed: "保存失败" }[state];
}

function hasUnsavedWork(state: EditorState): boolean {
  return state === "dirty" || state === "saving" || state === "conflict" || state === "failed";
}

function App() {
  const [capabilities, setCapabilities] = useState<Awaited<ReturnType<typeof gateway.getCapabilities>> | null>(null);
  const [repository, setRepository] = useState<RepositorySessionSnapshot | null>(null);
  const [files, setFiles] = useState<MarkdownFileEntry[]>([]);
  const [document, setDocument] = useState<DocumentSnapshot | null>(null);
  const [editorValue, setEditorValue] = useState("");
  const [editorState, setEditorState] = useState<EditorState>("clean");
  const [gitStatus, setGitStatus] = useState<GitStatusSnapshot | null>(null);
  const [notice, setNotice] = useState("正在检查桌面能力…");
  const [darkMode, setDarkMode] = useState(() => window.matchMedia("(prefers-color-scheme: dark)").matches);
  const previewHtml = useMemo(() => renderMarkdownPreview(editorValue), [editorValue]);

  useEffect(() => {
    void gateway.getCapabilities().then((snapshot) => {
      setCapabilities(snapshot);
      setNotice(snapshot.localEdit ? "请选择一个仓库开始编辑。" : "浏览器演示模式：仅展示只读样例。");
    }).catch(() => setNotice("无法读取桌面能力。请重新启动应用。"));
  }, []);

  async function chooseRepository() {
    if (hasUnsavedWork(editorState) && !window.confirm("当前文档有未保存修改。仍要切换仓库吗？")) return;
    try {
      const selectedPath = isTauriRuntime()
        ? await openDialog({ directory: true, multiple: false, title: "选择 RepoPress 仓库" })
        : "/演示/RepoPress";
      if (typeof selectedPath !== "string") return;
      const selected = await gateway.openRepository(selectedPath);
      setRepository(selected); setFiles(await gateway.listMarkdownFiles(selected.sessionId));
      setDocument(null); setEditorValue(""); setEditorState("clean"); setGitStatus(null);
      setNotice(`已打开：${selected.displayName}`);
    } catch (error) { setNotice(`无法打开仓库：${messageFrom(error)}`); }
  }

  async function selectDocument(file: MarkdownFileEntry) {
    if (!repository) return;
    if (hasUnsavedWork(editorState) && !window.confirm("当前文档有未保存修改。仍要切换吗？")) return;
    try {
      const nextDocument = await gateway.openDocument(repository.sessionId, file.relativePath);
      setDocument(nextDocument); setEditorValue(nextDocument.text); setEditorState("clean");
      setNotice(nextDocument.writable ? `正在编辑：${file.displayName}` : `以只读方式打开：${file.displayName}（${nextDocument.readOnlyReason ?? "当前格式不可安全保存"}）`);
    } catch (error) { setNotice(`无法打开文档：${messageFrom(error)}`); }
  }

  function updateDocument(value: string) { setEditorValue(value); if (document) setEditorState("dirty"); }

  async function saveDocument() {
    if (!repository || !document || editorState !== "dirty") return;
    setEditorState("saving");
    try {
      const result = await gateway.saveDocument({ sessionId: repository.sessionId, documentId: document.documentId, text: editorValue, expectedSha256: document.baselineSha256 });
      setDocument(result); setEditorValue(result.text); setEditorState("saved"); setNotice("已安全保存到本地仓库。");
    } catch (error) {
      const gatewayError = error as { code?: string; message?: string };
      if (gatewayError.code === "save_conflict") { setEditorState("conflict"); setNotice("文件已被外部修改；请重新打开文档后处理冲突。未覆盖磁盘文件。"); }
      else { setEditorState("failed"); setNotice(`保存失败：${messageFrom(error)}`); }
    }
  }

  async function refreshGitStatus() {
    if (!repository) return;
    try { setGitStatus(await gateway.gitStatus(repository.sessionId)); setNotice("Git 状态已刷新（仅查看）。"); }
    catch (error) { setNotice(`无法刷新 Git 状态：${messageFrom(error)}`); }
  }

  return <main className={darkMode ? "app-shell dark" : "app-shell"}>
    <header className="topbar">
      <div className="brand" aria-label="RepoPress 桌面版"><span className="brand-mark" aria-hidden="true">R</span><span>RepoPress</span><small>桌面 MVP</small></div>
      <div className="toolbar" aria-label="仓库操作">
        <button type="button" onClick={() => void chooseRepository()} aria-label="选择仓库">选择仓库</button>
        <button type="button" onClick={() => void saveDocument()} disabled={editorState !== "dirty"} aria-label="保存当前 Markdown 文档">保存</button>
        <button type="button" onClick={() => void refreshGitStatus()} disabled={!repository} aria-label="刷新 Git 状态">刷新 Git 状态</button>
        <button type="button" className="icon-button" onClick={() => setDarkMode((value) => !value)} aria-label="切换明暗色" title="切换明暗色">{darkMode ? "☀" : "☾"}</button>
      </div>
    </header>
    <p className="notice" role="status">{notice}</p>
    {capabilities && !capabilities.localEdit && <p className="demo-banner">演示模式不访问本地磁盘，保存和 Git 状态不会执行。</p>}
    <section className="workspace" aria-label="RepoPress 编辑工作区">
      <aside className="sidebar repository-panel" aria-label="仓库和 Markdown 文件">
        <div className="panel-heading"><span>仓库</span><span className="readonly-badge">本地</span></div>
        <p className="repository-name">{repository?.displayName ?? "尚未选择仓库"}</p><p className="repository-path">{repository?.rootPath ?? "使用顶部“选择仓库”开始"}</p>
        <div className="panel-heading files-heading"><span>Markdown 文件</span><span>{files.length}</span></div>
        <nav className="file-list" aria-label="Markdown 文件列表">{files.map((file) => <button key={file.relativePath} type="button" className={document?.relativePath === file.relativePath ? "file-button active" : "file-button"} onClick={() => void selectDocument(file)}><span aria-hidden="true">#</span><span className="file-label"><span>{file.displayName}</span><small>{file.directory || "仓库根目录"}</small></span></button>)}</nav>
        {gitStatus && <GitStatus status={gitStatus} />}
      </aside>
      <section className="editor-panel" aria-label="Markdown 编辑器">
        <div className="panel-heading"><span>{document?.relativePath ?? "选择一个 Markdown 文件"}</span><span className={`state-badge ${document && !document.writable ? "state-readonly" : `state-${editorState}`}`}>{document && !document.writable ? "只读" : editorStateLabel(editorState)}</span></div>
        <CodeMirror value={editorValue} height="100%" theme={darkMode ? oneDark : "light"} extensions={[markdown()]} onChange={updateDocument} editable={Boolean(document?.writable) && Boolean(capabilities?.localEdit)} aria-label="Markdown 编辑器" basicSetup={{ lineNumbers: true, foldGutter: false, highlightActiveLine: true }} />
      </section>
      <section className="preview-panel" aria-label="Markdown 预览"><div className="panel-heading"><span>Markdown 预览</span><span className="preview-warning">非站点构建</span></div><article className="markdown-preview" dangerouslySetInnerHTML={{ __html: previewHtml }} /></section>
    </section>
  </main>;
}

function GitStatus({ status }: { status: GitStatusSnapshot }) { return <section className="git-status" aria-label="Git 状态（只读）"><div className="panel-heading"><span>Git 状态</span><span className="readonly-badge">只读</span></div><p>{status.branch ?? "无可用分支"}</p><p>{status.available ? (status.changedFiles.length ? `${status.changedFiles.length} 项本地改动` : "工作区干净") : "当前目录不是 Git 仓库"}</p></section>; }
function messageFrom(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") return error.message;
  if (typeof error === "string") return error;
  return "未知错误";
}
function isTauriRuntime(): boolean { return "__TAURI_INTERNALS__" in window; }
export default App;
