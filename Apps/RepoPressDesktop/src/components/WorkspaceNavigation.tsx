import type { ReactNode } from "react";
import { useI18n } from "../i18n/i18n";

export type WorkspaceSection = "writing" | "library" | "rss" | "images" | "sync";
// Navigation nouns differ from the shared verb and inline site-kind label.
const navigationMessages = { "阅读": "Reading", "站点": "Site" };

const sections: { id: WorkspaceSection; label: string; icon: ReactNode }[] = [
  { id: "writing", label: "写作", icon: <><path d="m4 16-1 5 5-1L20 8l-4-4Z" /><path d="m14 6 4 4" /></> },
  { id: "library", label: "资料库", icon: <><path d="M3 4h7l2 2 2-2h7v16h-7l-2 2-2-2H3Z" /><path d="M12 6v16" /></> },
  { id: "rss", label: "阅读", icon: <><circle cx="5" cy="19" r="1" /><path d="M4 11a9 9 0 0 1 9 9M4 4a16 16 0 0 1 16 16" /></> },
  { id: "images", label: "图片工作台", icon: <><rect x="3" y="3" width="18" height="18" rx="3" /><circle cx="8" cy="8" r="1.5" /><path d="m3 17 5-5 4 4 4-6 5 7" /></> },
  { id: "sync", label: "站点", icon: <><path d="M20 8a8 8 0 0 0-14-3L3 8m0-5v5h5M4 16a8 8 0 0 0 14 3l3-3m0 5v-5h-5" /></> },
];

export interface WorkspaceNavigationProps {
  activeSection: WorkspaceSection;
  disabled?: boolean;
  onSelect: (section: WorkspaceSection) => void;
  onTools: () => void;
  onDrafts: () => void;
  onActivity: () => void;
  onSettings: () => void;
  draftsEnabled: boolean;
}

export function WorkspaceNavigation({ activeSection, disabled = false, onSelect, onTools, onDrafts, onActivity, onSettings, draftsEnabled }: WorkspaceNavigationProps) {
  const { t } = useI18n(navigationMessages);
  return <nav className="workspace-navigation" aria-label={t("主导航")}>
    <div className="workspace-navigation-primary">
      {sections.map(({ id, label, icon }) => <button key={id} type="button" className="workspace-navigation-item" aria-label={t(label)} aria-current={activeSection === id ? "page" : undefined} disabled={disabled} onClick={() => onSelect(id)} title={t(label)}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{icon}</svg><span>{t(label)}</span>
      </button>)}
    </div>
    <div className="workspace-navigation-secondary" aria-label={t("工作区工具")}>
      <button type="button" disabled={disabled} onClick={onTools}>{t("智能工具")}</button>
      <button type="button" disabled={disabled || !draftsEnabled} onClick={onDrafts}>{t("通用草稿")}</button>
      <button type="button" disabled={disabled} onClick={onActivity}>{t("操作日志")}</button>
      <button type="button" disabled={disabled} onClick={onSettings}>{t("设置")}</button>
    </div>
  </nav>;
}
