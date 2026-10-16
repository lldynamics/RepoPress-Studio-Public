import { useEffect, useRef } from "react";
import type { EditorExitState } from "../features/workspace/editorExit";
import { useI18n } from "../i18n/i18n";
import { lifecycleDialogMessages } from "../i18n/lifecycleDialogMessages";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import "./DraftLifecycleDialog.css";

export function EditorExitDialog({ state, onCancel, onFinish }: {
  state: EditorExitState & { errorPresentation?: UiMessage };
  onCancel: () => void;
  onFinish: (mode: "recovery" | "export") => void;
}) {
  const { t } = useI18n(lifecycleDialogMessages);
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    if (state.open) dialog.current?.showModal?.();
    else dialog.current?.close?.();
  }, [state.open]);
  return <dialog ref={dialog} className="draft-dialog editor-exit-dialog" aria-labelledby="editor-exit-title" onCancel={(event) => { event.preventDefault(); if (!state.busy) onCancel(); }}>
    <h2 id="editor-exit-title">{t("关闭 RepoPress")}</h2>
    <p>{t(state.snapshot?.dirty ? "当前文章有未保存修改。将先保存本机恢复草稿并读回校验，下次打开时可恢复。" : state.snapshot?.workspaceWarning ? "已有恢复文件无法读取。当前没有未保存文章，退出时将保留原恢复文件。" : "退出前将写入并读回校验本机工作区恢复状态。")}</p>
    <p>{t("此步骤保护主编辑器的当前文章。恢复包包含正文和来源信息，不包含图片或其他工作区数据。")}</p>
    {state.snapshot?.dirty && !state.snapshot.recoveryEnabled && <p>{t("自动恢复已关闭。请导出恢复包，或返回编辑并保存文章。")}</p>}
    {state.error && <p role="alert">{state.errorPresentation ? renderUiMessage(state.errorPresentation, t) : state.error}</p>}
    {state.exportPath && <p>{t("恢复包已写入：")}<code>{state.exportPath}</code></p>}
    {state.busy && <p role="status">{t("正在保存并校验，请稍候…")}</p>}
    <footer>
      <button type="button" onClick={onCancel} disabled={state.busy} autoFocus>{t("返回编辑")}</button>
      <button type="button" onClick={() => onFinish("export")} disabled={state.busy || !state.snapshot?.draft}>{t("导出恢复包并退出")}</button>
      <button type="button" onClick={() => onFinish("recovery")} disabled={state.busy || (state.snapshot?.dirty && !state.snapshot.recoveryEnabled)}>{t(state.snapshot?.dirty ? "保存恢复草稿并退出" : state.snapshot?.workspaceWarning ? "保留恢复文件并退出" : "校验并退出")}</button>
    </footer>
  </dialog>;
}
