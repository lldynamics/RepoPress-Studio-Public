import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import { lifecycleDialogMessages } from "../i18n/lifecycleDialogMessages";
import "./DraftLifecycleDialog.css";

export type DraftLifecycleMode = "create" | "rename" | "delete";

interface DraftLifecycleDialogProps {
  open: boolean;
  mode: DraftLifecycleMode;
  currentPath?: string | null;
  suggestedPath?: string;
  busy?: boolean;
  error?: string | null;
  onClose: () => void;
  onSubmit: (relativePath?: string) => void | Promise<void>;
}

const COPY: Record<DraftLifecycleMode, { title: string; description: string; action: string }> = {
  create: {
    title: "新建 Markdown 文章",
    description: "文件会直接创建在当前仓库中，并在创建后打开。",
    action: "创建并打开",
  },
  rename: {
    title: "移动或重命名文章",
    description: "输入仓库内的新路径。已有文件不会被覆盖。",
    action: "确认重命名",
  },
  delete: {
    title: "删除这篇文章？",
    description: "这会从本地仓库删除文件。为防止误删，文件在磁盘上发生变化时操作会被拒绝。",
    action: "删除文章",
  },
};

export function DraftLifecycleDialog({
  open,
  mode,
  currentPath,
  suggestedPath = "content/new-article.md",
  busy = false,
  error,
  onClose,
  onSubmit,
}: DraftLifecycleDialogProps) {
  const { t } = useI18n(lifecycleDialogMessages);
  const [relativePath, setRelativePath] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const copy = COPY[mode];

  useEffect(() => {
    if (!open) return;
    setRelativePath(mode === "rename" ? currentPath ?? "" : suggestedPath);
    const frame = window.requestAnimationFrame(() => inputRef.current?.focus());
    return () => window.cancelAnimationFrame(frame);
  }, [open, mode, currentPath, suggestedPath]);

  useEffect(() => {
    if (!open) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busy) {
        event.preventDefault();
        onClose();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [open, busy, onClose]);

  if (!open) return null;

  const trimmedPath = relativePath.trim();
  const canSubmit = mode === "delete" || (trimmedPath.length > 0 && (mode !== "rename" || trimmedPath !== currentPath));

  return <div className="draft-dialog-scrim" role="presentation" onMouseDown={(event) => {
    if (event.target === event.currentTarget && !busy) onClose();
  }}>
    <section className="draft-dialog" role="dialog" aria-modal="true" aria-labelledby="draft-dialog-title" aria-describedby="draft-dialog-description">
      <header>
        <span className={`draft-dialog-icon ${mode === "delete" ? "danger" : ""}`} aria-hidden="true">
          {mode === "create" ? "+" : mode === "rename" ? "↗" : "!"}
        </span>
        <div>
          <h2 id="draft-dialog-title">{t(copy.title)}</h2>
          <p id="draft-dialog-description">{t(copy.description)}</p>
        </div>
      </header>

      {mode === "delete" ? <div className="draft-delete-target">
        <span>{t("即将删除")}</span>
        <code>{currentPath}</code>
      </div> : <label className="draft-path-field">
        <span>{t("仓库内路径")}</span>
        <input
          ref={inputRef}
          value={relativePath}
          disabled={busy}
          spellCheck={false}
          autoComplete="off"
          placeholder={t("content/my-article.md")}
          onChange={(event) => setRelativePath(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && canSubmit && !busy) {
              event.preventDefault();
              void onSubmit(trimmedPath);
            }
          }}
        />
        <small>{t("支持 .md 或 .markdown；路径必须位于当前仓库内。")}</small>
      </label>}

      {error && <p className="draft-dialog-error" role="alert">{error}</p>}

      <footer>
        <button type="button" onClick={onClose} disabled={busy}>{t("取消")}</button>
        <button
          type="button"
          className={mode === "delete" ? "danger" : "primary"}
          disabled={!canSubmit || busy}
          onClick={() => void onSubmit(mode === "delete" ? undefined : trimmedPath)}
        >{busy ? t("正在处理…") : t(copy.action)}</button>
      </footer>
    </section>
  </div>;
}
