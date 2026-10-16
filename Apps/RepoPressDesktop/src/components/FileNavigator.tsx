import { useI18n } from "../i18n/i18n";
import { useEffect, useMemo, useRef, useState } from "react";
import type { MarkdownFileEntry, MarkdownSearchResult, MarkdownSearchSnapshot } from "../contracts/repository";
import { buildMarkdownFileTree, type FileTreeNode } from "../features/files/fileTree";

interface FileNavigatorProps {
  files: MarkdownFileEntry[];
  selectedPath: string | undefined;
  sessionId: string | undefined;
  onOpenFile: (file: MarkdownFileEntry) => void;
  onOpenSearchResult: (match: MarkdownSearchResult, query: string) => void;
  search: (sessionId: string, query: string, limit?: number) => Promise<MarkdownSearchSnapshot>;
}

type SearchState = "idle" | "loading" | "error" | "complete";

export function FileNavigator({ files, selectedPath, sessionId, onOpenFile, onOpenSearchResult, search }: FileNavigatorProps) {
  const { t } = useI18n();
  const [query, setQuery] = useState("");
  const [searchState, setSearchState] = useState<SearchState>("idle");
  const [result, setResult] = useState<MarkdownSearchSnapshot | null>(null);
  const [resultSessionId, setResultSessionId] = useState<string | undefined>();
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const requestNumber = useRef(0);
  const tree = useMemo(() => buildMarkdownFileTree(files), [files]);

  useEffect(() => {
    setQuery(""); setResult(null); setResultSessionId(undefined); setSearchState("idle"); setExpanded(new Set()); requestNumber.current += 1;
  }, [sessionId]);

  useEffect(() => {
    const trimmed = query.trim();
    const requestId = ++requestNumber.current;
    if (!trimmed || !sessionId) { setResult(null); setResultSessionId(undefined); setSearchState("idle"); return; }
    setResult(null); setResultSessionId(undefined); setSearchState("loading");
    const timer = window.setTimeout(() => {
      void search(sessionId, trimmed, 100).then((snapshot) => {
        if (requestId !== requestNumber.current) return;
        setResult(snapshot); setResultSessionId(sessionId); setSearchState("complete");
      }).catch(() => {
        if (requestId !== requestNumber.current) return;
        setResult(null); setResultSessionId(undefined); setSearchState("error");
      });
    }, 250);
    return () => { window.clearTimeout(timer); requestNumber.current += 1; };
  }, [query, search, sessionId]);

  const toggleDirectory = (path: string) => setExpanded((previous) => {
    const next = new Set(previous); if (next.has(path)) next.delete(path); else next.add(path); return next;
  });

  const trimmedQuery = query.trim();
  const displayedResult = result && resultSessionId === sessionId && result.query === trimmedQuery ? result : null;

  return <>
    <label className="search-label" htmlFor="markdown-search">{t("搜索 Markdown")}</label>
    <input id="markdown-search" className="file-search" type="search" value={query} onChange={(event) => { requestNumber.current += 1; setResult(null); setResultSessionId(undefined); setQuery(event.target.value); }} placeholder={t("按路径或正文搜索")} autoComplete="off" />
    {!trimmedQuery ? <nav className="file-tree" role="tree" aria-label={t("Markdown 文件树")} onKeyDown={moveTreeFocus}>
      {tree.map((node) => <TreeNode key={node.kind === "directory" ? node.relativePath : node.file.relativePath} node={node} level={1} expanded={expanded} selectedPath={selectedPath} onToggle={toggleDirectory} onOpenFile={onOpenFile} />)}
      {!files.length && <p className="empty-state">{t("未找到 Markdown 文件。")}</p>}
    </nav> : <SearchResults state={searchState} result={displayedResult} selectedPath={selectedPath} onOpenSearchResult={onOpenSearchResult} />}
  </>;
}

function TreeNode({ node, level, expanded, selectedPath, onToggle, onOpenFile }: { node: FileTreeNode; level: number; expanded: Set<string>; selectedPath: string | undefined; onToggle: (path: string) => void; onOpenFile: (file: MarkdownFileEntry) => void }) {
  if (node.kind === "file") return <FileButton file={node.file} level={level} selectedPath={selectedPath} onOpenFile={onOpenFile} />;
  const isExpanded = expanded.has(node.relativePath);
  return <div className="tree-directory" role="treeitem" aria-level={level} aria-expanded={isExpanded} tabIndex={0} onKeyDown={(event) => { if (event.target !== event.currentTarget) return; if (event.key === "ArrowRight" && !isExpanded) { event.preventDefault(); onToggle(node.relativePath); } else if (event.key === "ArrowLeft" && isExpanded) { event.preventDefault(); onToggle(node.relativePath); } else if (event.key === "Enter" || event.key === " ") { event.preventDefault(); onToggle(node.relativePath); } }} onClick={(event) => { if (!(event.target as HTMLElement).closest('[role="group"]')) onToggle(node.relativePath); }}>
    <span className="directory-button"><span aria-hidden="true">{isExpanded ? "▾" : "▸"}</span>{node.name}</span>
    {isExpanded && <div className="tree-children" role="group">{node.children.map((child) => <TreeNode key={child.kind === "directory" ? child.relativePath : child.file.relativePath} node={child} level={level + 1} expanded={expanded} selectedPath={selectedPath} onToggle={onToggle} onOpenFile={onOpenFile} />)}</div>}
  </div>;
}

function SearchResults({ state, result, selectedPath, onOpenSearchResult }: { state: SearchState; result: MarkdownSearchSnapshot | null; selectedPath: string | undefined; onOpenSearchResult: (match: MarkdownSearchResult, query: string) => void }) {
  const { t } = useI18n();
  if (state === "loading") return <p className="search-state" role="status">{t("正在搜索…")}</p>;
  if (state === "error") return <p className="search-state error" role="alert">{t("搜索失败，请重试。")}</p>;
  if (!result?.results.length) return <>
    {result?.truncated && <p className="search-state">{t("搜索已达到安全扫描上限，结果可能不完整。")}</p>}
    <p className="search-state">{t("没有匹配的 Markdown 文档。")}</p>
  </>;
  return <div className="search-results" aria-label={t("Markdown 搜索结果")}>
    {result.truncated && <p className="search-state">{t("搜索已达到安全扫描上限，仅显示当前结果。")}</p>}
    {result.results.map((match) => <SearchResultButton key={`${match.relativePath}:${match.matchKind}:${match.lineNumber ?? "path"}:${match.snippet}`} match={match} query={result.query} selectedPath={selectedPath} onOpenSearchResult={onOpenSearchResult} />)}
  </div>;
}

function SearchResultButton({ match, query, selectedPath, onOpenSearchResult }: { match: MarkdownSearchResult; query: string; selectedPath: string | undefined; onOpenSearchResult: (match: MarkdownSearchResult, query: string) => void }) {
  const { t } = useI18n();
  return <button type="button" className={selectedPath === match.relativePath ? "file-button active" : "file-button"} onClick={() => onOpenSearchResult(match, query)}>
    <span className="match-badge">{match.matchKind === "path" ? t("路径") : t("正文")}</span>
    <span className="file-label"><span>{match.relativePath}{match.lineNumber ? `:${match.lineNumber}` : ""}</span><small>{match.snippet}</small></span>
  </button>;
}

function FileButton({ file, level, selectedPath, onOpenFile }: { file: MarkdownFileEntry; level: number; selectedPath: string | undefined; onOpenFile: (file: MarkdownFileEntry) => void }) {
  const { t } = useI18n();
  return <button type="button" role="treeitem" aria-level={level} aria-selected={selectedPath === file.relativePath} className={selectedPath === file.relativePath ? "file-button active" : "file-button"} onKeyDown={(event) => { if (event.key === "ArrowRight" || event.key === "Enter") { event.preventDefault(); onOpenFile(file); } }} onClick={() => onOpenFile(file)}><span aria-hidden="true">#</span><span className="file-label"><span>{file.displayName}</span><small>{file.directory || t("仓库根目录")}</small></span></button>;
}

function moveTreeFocus(event: React.KeyboardEvent<HTMLElement>) {
  if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
  const items = Array.from(event.currentTarget.querySelectorAll<HTMLElement>('[role="treeitem"]'));
  const current = (event.target as HTMLElement).closest<HTMLElement>('[role="treeitem"]');
  if (!current || items.length === 0) return;
  const currentIndex = items.indexOf(current);
  const nextIndex = event.key === "Home" ? 0
    : event.key === "End" ? items.length - 1
    : Math.min(items.length - 1, Math.max(0, currentIndex + (event.key === "ArrowDown" ? 1 : -1)));
  event.preventDefault();
  items[nextIndex]?.focus();
}
