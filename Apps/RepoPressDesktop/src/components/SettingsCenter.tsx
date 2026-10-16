import { WorkspaceBackupSettingsSection } from "./WorkspaceBackupSettingsSection";
import { useEffect, useRef, useState } from "react";
import type { RecentRepositorySnapshot, WorkspacePreferences } from "../contracts/repository";
import { DEFAULT_WORKSPACE_PREFERENCES, clampEditorFontSize, normalizeWorkspacePreferences } from "../features/workspace/workspaceRecovery";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { useI18n, type MessageParameters } from "../i18n/i18n";

interface SettingsCenterProps {
  open: boolean;
  preferences: WorkspacePreferences;
  recentRepositories: RecentRepositorySnapshot[];
  canOpenRecent: boolean;
  onClose: () => void;
  onSave: (preferences: WorkspacePreferences) => Promise<void>;
  onOpenRecent: (path: string) => Promise<boolean>;
}

export function SettingsCenter({ open, preferences, recentRepositories, canOpenRecent, onClose, onSave, onOpenRecent }: SettingsCenterProps) {
  const { t } = useI18n();
  const [draft, setDraft] = useState(preferences);
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<{ source: string; parameters?: MessageParameters } | null>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const drawer = useRef<HTMLElement>(null);
  useDrawerFocus(open, drawer, onClose);

  useEffect(() => { if (open) { setDraft(preferences); setStatus(null); queueMicrotask(() => closeButton.current?.focus()); } }, [open, preferences]);

  async function save() {
    setSaving(true); setStatus(null);
    try { await onSave(normalizeWorkspacePreferences(draft)); setStatus({ source: "设置已保存并立即应用。" }); }
    catch (error) { setStatus({ source: "无法保存设置：{message}", parameters: { message: messageFrom(error) } }); }
    finally { setSaving(false); }
  }

  async function openRecent(path: string) {
    setStatus(null);
    try { if (await onOpenRecent(path)) onClose(); }
    catch (error) { setStatus({ source: "无法打开最近仓库：{message}", parameters: { message: messageFrom(error) } }); }
  }

  function restoreEditorDefaults() {
    setDraft((value) => ({
      ...DEFAULT_WORKSPACE_PREFERENCES,
      theme: value.theme,
      uiLanguage: value.uiLanguage,
      restoreLastWorkspace: value.restoreLastWorkspace,
      recoveryEnabled: value.recoveryEnabled,
    }));
    setStatus({ source: "已恢复编辑器默认设置；主题和工作区恢复设置保持不变。" });
  }

  return <aside ref={drawer} className={`settings-center ${open ? "open" : ""}`} role="dialog" aria-modal="true" aria-labelledby="settings-center-title" aria-hidden={!open} inert={!open} tabIndex={-1}>
    <header className="settings-header">
      <div><h1 id="settings-center-title">{t("设置中心")}</h1><p>{t("这些设置保存在桌面应用的工作区状态中。")}</p></div>
      <button ref={closeButton} className="settings-close" type="button" onClick={onClose} aria-label={t("关闭设置中心")}>×</button>
    </header>
    <div className="settings-content">
      <section className="settings-section" aria-labelledby="appearance-settings">
        <h2 id="appearance-settings">{t("外观与编辑器")}</h2>
        <label>{t("主题")}
          <select value={draft.theme} onChange={(event) => setDraft((value) => ({ ...value, theme: event.target.value as WorkspacePreferences["theme"] }))}>
            <option value="system">{t("跟随系统")}</option><option value="light">{t("浅色")}</option><option value="dark">{t("深色")}</option>
          </select>
        </label>
        <label>{t("编辑器字号：{size}px", { size: draft.editorFontSize })}
          <input type="range" min="12" max="28" value={draft.editorFontSize} onChange={(event) => setDraft((value) => ({ ...value, editorFontSize: clampEditorFontSize(event.target.value) }))} />
        </label>
        <label>{t("行距：{size}px", { size: draft.editorLineSpacing })}
          <input type="range" min="0" max="12" value={draft.editorLineSpacing} onChange={(event) => setDraft((value) => ({ ...value, editorLineSpacing: Number(event.target.value) }))} />
        </label>
        <label>{t("正文宽度：{size}px", { size: draft.editorBodyWidth })}
          <input type="range" min="560" max="1200" step="20" value={draft.editorBodyWidth} onChange={(event) => setDraft((value) => ({ ...value, editorBodyWidth: Number(event.target.value) }))} />
        </label>
        <label>{t("写作工具密度")}
          <select value={draft.writingToolDensity} onChange={(event) => setDraft((value) => ({ ...value, writingToolDensity: event.target.value as WorkspacePreferences["writingToolDensity"] }))}>
            <option value="basic">{t("基础")}</option><option value="professional">{t("专业")}</option>
          </select>
        </label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.spellCheckEnabled} onChange={(event) => setDraft((value) => ({ ...value, spellCheckEnabled: event.target.checked }))} />{t("启用拼写检查")}</label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.typewriterModeEnabled} onChange={(event) => setDraft((value) => ({ ...value, typewriterModeEnabled: event.target.checked }))} />{t("启用打字机模式")}</label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.currentParagraphHighlightEnabled} onChange={(event) => setDraft((value) => ({ ...value, currentParagraphHighlightEnabled: event.target.checked }))} />{t("高亮当前段落")}</label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.warmPaperBackgroundEnabled} onChange={(event) => setDraft((value) => ({ ...value, warmPaperBackgroundEnabled: event.target.checked }))} />{t("使用暖色纸张背景")}</label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.automaticPairingEnabled} onChange={(event) => setDraft((value) => ({ ...value, automaticPairingEnabled: event.target.checked }))} />{t("自动配对括号与引号")}</label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.paragraphSpotlightEnabled} onChange={(event) => setDraft((value) => ({ ...value, paragraphSpotlightEnabled: event.target.checked }))} />{t("段落聚光灯")}</label>
        <label>{t("界面语言")}
          <select value={draft.uiLanguage ?? "zh-CN"} onChange={(event) => setDraft((value) => ({ ...value, uiLanguage: event.target.value as WorkspacePreferences["uiLanguage"] }))}>
            <option value="zh-CN">简体中文</option><option value="en-US">English</option><option value="system">{t("跟随系统")}</option>
          </select>
        </label>
        <button type="button" onClick={restoreEditorDefaults} disabled={saving}>{t("恢复编辑器默认设置")}</button>
      </section>
      <section className="settings-section" aria-labelledby="workspace-settings">
        <h2 id="workspace-settings">{t("工作区")}</h2>
        <label className="settings-toggle"><input type="checkbox" checked={draft.restoreLastWorkspace} onChange={(event) => setDraft((value) => ({ ...value, restoreLastWorkspace: event.target.checked }))} />{t("启动时恢复上次打开的仓库和文档")}</label>
        <label className="settings-toggle"><input type="checkbox" checked={draft.recoveryEnabled} onChange={(event) => setDraft((value) => ({ ...value, recoveryEnabled: event.target.checked }))} />{t("为未保存修改保留崩溃恢复草稿")}</label>
      </section>
      <section className="settings-section" aria-labelledby="recent-repositories">
        <h2 id="recent-repositories">{t("最近仓库")}</h2>
        {recentRepositories.length === 0 ? <p className="settings-muted">{t("尚无最近打开的本地仓库。")}</p> : <div className="recent-repositories">{recentRepositories.map((repository) => <button key={repository.path} type="button" onClick={() => void openRecent(repository.path)} disabled={!canOpenRecent || saving} title={canOpenRecent ? repository.path : t("浏览器演示不能打开本地路径")}><strong>{repository.displayName}</strong><small>{repository.path}</small></button>)}</div>}
      </section>
      <WorkspaceBackupSettingsSection open={open} enabled={canOpenRecent} disabled={saving} />
      <div className="settings-actions"><button type="button" onClick={() => void save()} disabled={saving}>{saving ? t("正在保存…") : t("保存设置")}</button><button type="button" onClick={onClose}>{t("关闭")}</button></div>
      {status && <p className="settings-status" role="status">{t(status.source, status.parameters)}</p>}
    </div>
  </aside>;
}

function messageFrom(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") return error.message;
  return "未知错误";
}
