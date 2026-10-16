import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { saveConflictReviewIdentity, validateSaveConflictMergedTextBudget, validateSaveConflictReviewBudget, type SaveConflictReviewSnapshot } from "../features/workspace/saveConflictReview";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import "./SaveConflictReview.css";

export type { SaveConflictReviewSnapshot } from "../features/workspace/saveConflictReview";

export interface SaveConflictReviewProps {
  open: boolean;
  review: SaveConflictReviewSnapshot | null;
  busy: boolean;
  error?: string;
  onClose: () => void;
  onReload: () => void;
  onApply: (mergedText: string) => Promise<void>;
}

export function SaveConflictReview({ open, review, busy, error, onClose, onReload, onApply }: SaveConflictReviewProps) {
  const root = useRef<HTMLDivElement>(null);
  const mergedInput = useRef<HTMLTextAreaElement>(null);
  const generation = useRef(0);
  const currentIdentity = useRef<string | null>(null);
  const applyingRef = useRef(false);
  const [mergedText, setMergedText] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [reloadConfirming, setReloadConfirming] = useState(false);
  const [applying, setApplying] = useState(false);
  const [applyError, setApplyError] = useState("");
  const budget = useMemo(() => review ? validateSaveConflictReviewBudget(review) : null, [review]);
  const identity = review && budget?.ok ? saveConflictReviewIdentity(review) : null;
  const readable = Boolean(review && budget?.ok);
  const mergedBudget = useMemo(() => validateSaveConflictMergedTextBudget(mergedText), [mergedText]);
  const effectiveBusy = busy || applying;

  const clearDraft = useCallback(() => {
    generation.current += 1;
    applyingRef.current = false;
    setMergedText("");
    setConfirming(false);
    setReloadConfirming(false);
    setApplying(false);
    setApplyError("");
  }, []);

  const close = useCallback(() => {
    if (busy || applyingRef.current) return;
    clearDraft();
    onClose();
  }, [busy, clearDraft, onClose]);
  useDrawerFocus(open, root, close);

  useLayoutEffect(() => {
    generation.current += 1;
    applyingRef.current = false;
    currentIdentity.current = identity;
    setConfirming(false);
    setReloadConfirming(false);
    setApplying(false);
    setApplyError("");
    setMergedText(open && readable && review ? review.localText : "");
  }, [identity, open, readable]);

  const reload = () => {
    if (effectiveBusy) return;
    if (review && mergedText !== review.localText) {
      setConfirming(false);
      setReloadConfirming(true);
      return;
    }
    setConfirming(false);
    setReloadConfirming(false);
    setApplyError("");
    onReload();
  };

  const confirmReload = () => {
    if (effectiveBusy) return;
    setConfirming(false);
    setReloadConfirming(false);
    setApplyError("");
    if (review) setMergedText(review.localText);
    onReload();
  };

  const apply = async () => {
    if (!review || !readable || !confirming || busy || applyingRef.current || !identity || !mergedBudget.ok) return;
    const capturedIdentity = identity;
    const capturedGeneration = generation.current;
    const capturedText = mergedText;
    applyingRef.current = true;
    setApplying(true);
    setApplyError("");
    try {
      await onApply(capturedText);
    } catch (caught) {
      if (generation.current === capturedGeneration && currentIdentity.current === capturedIdentity) {
        applyingRef.current = false;
        setApplying(false);
        const message = caught instanceof Error && caught.message.trim() ? caught.message.trim() : "载入合并稿失败，原稿和磁盘文件均未由此窗口写入。可修改合并稿后重试。";
        setApplyError(message);
        // Let React commit the enabled textarea, then focus it after the
        // drawer's initial focus microtask has completed.
        setTimeout(() => mergedInput.current?.focus(), 0);
      }
    }
  };

  if (!open) return null;
  const fatalError = !review ? error || "无法读取冲突内容；未将缺失内容当作空文件显示。" : !budget || !budget.ok ? error || budget?.message || "无法验证冲突内容大小。" : "";
  const displayError = error || applyError;
  return <div className="save-conflict-review-backdrop" ref={root}>
    <section className="save-conflict-review" role="dialog" aria-modal="true" aria-labelledby="save-conflict-review-title" aria-busy={effectiveBusy} tabIndex={-1}>
      <header><div><h2 id="save-conflict-review-title">保存冲突审阅</h2><p>{review ? review.relativePath : "未读取到文件路径"}</p></div><button type="button" onClick={close} disabled={effectiveBusy} aria-label="关闭保存冲突审阅">×</button></header>
      {!review && busy ? <div className="save-conflict-review-content"><p role="status">正在读取冲突内容…</p></div> : fatalError ? <div className="save-conflict-review-content"><p className="save-conflict-review-error" role="alert">{fatalError}</p><div className="save-conflict-review-actions"><button type="button" onClick={reload} disabled={effectiveBusy}>重新读取磁盘内容</button></div></div> : <div className="save-conflict-review-content">
        {displayError && <p className="save-conflict-review-error" role="alert">{displayError}</p>}
        <p className="save-conflict-review-note">三份内容均以纯文本完整显示。请手动编辑合并稿；不会自动选择版本、丢弃本地稿或覆盖磁盘文件。</p>
        <div className="save-conflict-review-sources" aria-label="冲突文本版本">
          <label>上次加载<pre data-testid="conflict-baseline">{review!.baselineText}</pre></label>
          <label>本地未保存<pre data-testid="conflict-local">{review!.localText}</pre></label>
          <label>磁盘当前内容<pre data-testid="conflict-disk">{review!.diskText}</pre></label>
        </div>
        <label className="save-conflict-review-merge">合并稿<textarea ref={mergedInput} aria-label="合并稿" value={mergedText} onChange={(event) => { setMergedText(event.target.value); setApplyError(""); }} disabled={effectiveBusy} spellCheck="false" /></label>
        <p className="save-conflict-review-boundary">确认后会将本地未保存原稿备份到“通用草稿”，然后只把合并稿载入编辑缓冲区；不会写回仓库。请在审阅后另行保存。</p>
        <div className="save-conflict-review-actions"><button type="button" onClick={reload} disabled={effectiveBusy}>重新读取磁盘内容</button><button type="button" onClick={() => setConfirming(true)} disabled={effectiveBusy}>备份原稿并载入合并稿</button></div>
        {!mergedBudget.ok && <p className="save-conflict-review-error" role="alert">{mergedBudget.message}</p>}
        {confirming && <section className="save-conflict-review-confirm" role="alertdialog" aria-label="确认备份原稿并载入合并稿"><p>将备份本地未保存原稿到“通用草稿”，并把当前合并稿载入编辑缓冲区。此操作不会写回仓库；之后仍需另行保存。</p><div><button type="button" onClick={() => setConfirming(false)} disabled={effectiveBusy}>取消</button><button type="button" onClick={() => void apply()} disabled={effectiveBusy || !mergedBudget.ok}>确认：备份原稿并载入合并稿</button></div></section>}
        {reloadConfirming && <section className="save-conflict-review-confirm" role="alertdialog" aria-label="确认重新读取磁盘内容"><p>重新读取会丢弃尚未载入编辑缓冲区的合并草案，并恢复为本地未保存版本。是否继续？</p><div><button type="button" onClick={() => setReloadConfirming(false)} disabled={effectiveBusy}>取消</button><button type="button" onClick={confirmReload} disabled={effectiveBusy}>确认重新读取</button></div></section>}
        {effectiveBusy && <p role="status">正在载入合并稿…</p>}
      </div>}
    </section>
  </div>;
}
