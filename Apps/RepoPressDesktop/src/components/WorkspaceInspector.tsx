import { useId, useRef, type KeyboardEvent, type ReactNode } from "react";
import { useI18n } from "../i18n/i18n";
import "./WorkspaceInspector.css";

export interface WorkspaceInspectorTab {
  id: string;
  label: string;
  content: ReactNode;
}

export interface WorkspaceInspectorProps {
  tabs: WorkspaceInspectorTab[];
  activeTab: string;
  onSelectTab: (id: string) => void;
  onClose: () => void;
  disabled?: boolean;
}

export function WorkspaceInspector({ tabs, activeTab, onSelectTab, onClose, disabled = false }: WorkspaceInspectorProps) {
  const { t } = useI18n();
  const instanceId = useId().replace(/:/g, "");
  const tabRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const requestedIndex = tabs.findIndex((tab) => tab.id === activeTab);
  const selectedIndex = requestedIndex >= 0 ? requestedIndex : 0;

  function selectAndFocus(index: number) {
    const tab = tabs[index];
    if (!tab || disabled) return;
    onSelectTab(tab.id);
    tabRefs.current[index]?.focus();
  }

  function handleKeyDown(index: number, event: KeyboardEvent<HTMLButtonElement>) {
    if (disabled || tabs.length === 0) return;
    let nextIndex: number | null = null;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") nextIndex = (index + 1) % tabs.length;
    else if (event.key === "ArrowLeft" || event.key === "ArrowUp") nextIndex = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") nextIndex = 0;
    else if (event.key === "End") nextIndex = tabs.length - 1;
    if (nextIndex === null) return;
    event.preventDefault();
    selectAndFocus(nextIndex);
  }

  return <section className="workspace-inspector" aria-label={t("文章检查器")}>
    <header className="workspace-inspector-header">
      <div className="workspace-inspector-tabs" role="tablist" aria-label={t("文章检查器面板")}>
        {tabs.map((tab, index) => {
          const selected = index === selectedIndex;
          const tabId = `${instanceId}-inspector-tab-${index}`;
          const panelId = `${instanceId}-inspector-panel-${index}`;
          return <button
            key={tab.id}
            ref={(node) => { tabRefs.current[index] = node; }}
            id={tabId}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-controls={panelId}
            tabIndex={selected ? 0 : -1}
            disabled={disabled}
            onClick={() => onSelectTab(tab.id)}
            onKeyDown={(event) => handleKeyDown(index, event)}
          >{t(tab.label)}</button>;
        })}
      </div>
      <button type="button" className="workspace-inspector-close" aria-label={t("关闭文章检查器")} disabled={disabled} onClick={onClose}>×</button>
    </header>
    <div className="workspace-inspector-panels">
      {tabs.map((tab, index) => {
        const selected = index === selectedIndex;
        return <div
          key={tab.id}
          id={`${instanceId}-inspector-panel-${index}`}
          className="workspace-inspector-panel"
          role="tabpanel"
          aria-labelledby={`${instanceId}-inspector-tab-${index}`}
          hidden={!selected}
          tabIndex={0}
        >{tab.content}</div>;
      })}
    </div>
  </section>;
}
