import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import {
  calculateWorkspaceLayout,
  readWorkspaceLayoutPreference,
  resizeWorkspacePanel,
  workspacePanelBounds,
  writeWorkspaceLayoutPreference,
  type WorkspaceLayoutPreference,
  type WorkspacePanel,
} from "../features/workspace/workspaceLayout";
import { useI18n } from "../i18n/i18n";
import "./ResizableWorkspace.css";

export interface ResizableWorkspaceProps {
  active?: boolean;
  sidebar?: ReactNode;
  editor: ReactNode;
  preview?: ReactNode;
  inspector?: ReactNode;
  inspectorVisible?: boolean;
  className?: string;
}

type InspectorPosition = "hidden" | "docked" | "bottom";

interface ActiveResize {
  panel: WorkspacePanel;
  pointerId: number;
  startX: number;
  startPreference: WorkspaceLayoutPreference;
  startWidth: number;
  inspectorPosition: InspectorPosition;
}

const DOCKED_INSPECTOR_BREAKPOINT = 1280;
const DOCKED_INSPECTOR_WIDTH = 320;

function browserStorage(): Storage | null {
  try { return typeof window === "undefined" ? null : window.localStorage; }
  catch { return null; }
}

export function ResizableWorkspace({ sidebar, editor, preview, inspector, inspectorVisible = true, className, active = true }: ResizableWorkspaceProps) {
  const { t } = useI18n();
  const rootRef = useRef<HTMLElement>(null);
  const activeResizeRef = useRef<ActiveResize | null>(null);
  const [containerWidth, setContainerWidth] = useState(0);
  const [preference, setPreference] = useState<WorkspaceLayoutPreference>(() => readWorkspaceLayoutPreference(browserStorage()));
  const [activePanel, setActivePanel] = useState<WorkspacePanel | null>(null);
  const [narrowSidebarExpanded, setNarrowSidebarExpanded] = useState(false);
  const sidebarVisible = sidebar != null;
  const previewVisible = preview != null;
  const inspectorPresent = inspector != null;
  const inspectorShown = inspectorPresent && inspectorVisible;
  const inspectorPosition: InspectorPosition = !inspectorShown
    ? "hidden"
    : containerWidth >= DOCKED_INSPECTOR_BREAKPOINT ? "docked" : "bottom";
  const layoutWidth = inspectorPosition === "docked"
    ? Math.max(0, containerWidth - DOCKED_INSPECTOR_WIDTH)
    : containerWidth;
  const layout = useMemo(() => calculateWorkspaceLayout({
    containerWidth: layoutWidth,
    sidebarVisible,
    previewVisible,
    preference,
  }), [layoutWidth, preference, previewVisible, sidebarVisible]);

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const measure = () => {
      const width = Math.round(root.getBoundingClientRect().width || root.clientWidth);
      setContainerWidth((current) => current === width ? current : width);
    };
    measure();
    if (typeof ResizeObserver === "function") {
      const observer = new ResizeObserver((entries) => {
        const entry = entries.find((candidate) => candidate.target === root);
        const observedWidth = entry?.contentRect.width ?? root.getBoundingClientRect().width;
        const width = Math.round(observedWidth || root.clientWidth);
        setContainerWidth((current) => current === width ? current : width);
      });
      observer.observe(root);
      return () => observer.disconnect();
    }
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, []);

  useLayoutEffect(() => {
    const active = activeResizeRef.current;
    if (!active) return;
    const handleStillAvailable = active.panel === "sidebar"
      ? sidebarVisible && layout.mode !== "narrow" && layout.sidebarResizable
      : previewVisible && layout.mode === "wide" && layout.previewResizable;
    if (handleStillAvailable && active.inspectorPosition === inspectorPosition) return;
    activeResizeRef.current = null;
    setActivePanel(null);
    setPreference(active.startPreference);
  }, [activePanel, inspectorPosition, layout.mode, layout.previewResizable, layout.sidebarResizable, previewVisible, sidebarVisible]);

  useEffect(() => {
    if (layout.mode !== "narrow" || !sidebarVisible) setNarrowSidebarExpanded(false);
  }, [layout.mode, sidebarVisible]);

  function changePanelWidth(panel: WorkspacePanel, requestedWidth: number, persist: boolean) {
    setPreference((current) => {
      const next = resizeWorkspacePanel(current, layout, panel, requestedWidth);
      if (persist) writeWorkspaceLayoutPreference(next, browserStorage());
      return next;
    });
  }

  function finishPointer(event: ReactPointerEvent<HTMLDivElement>, cancelled: boolean) {
    const active = activeResizeRef.current;
    if (!active || active.pointerId !== event.pointerId) return;
    activeResizeRef.current = null;
    setActivePanel(null);
    if (cancelled) setPreference(active.startPreference);
    else setPreference((current) => {
      writeWorkspaceLayoutPreference(current, browserStorage());
      return current;
    });
    if (event.currentTarget.hasPointerCapture?.(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  }

  function startPointer(panel: WorkspacePanel, event: ReactPointerEvent<HTMLDivElement>) {
    if (event.button !== 0) return;
    const resizable = panel === "sidebar" ? layout.sidebarResizable : layout.previewResizable;
    if (!resizable) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    activeResizeRef.current = {
      panel,
      pointerId: event.pointerId,
      startX: event.clientX,
      startPreference: preference,
      startWidth: panel === "sidebar" ? layout.sidebarWidth : layout.previewWidth,
      inspectorPosition,
    };
    setActivePanel(panel);
  }

  function movePointer(event: ReactPointerEvent<HTMLDivElement>) {
    const active = activeResizeRef.current;
    if (!active || active.pointerId !== event.pointerId) return;
    const physicalDelta = event.clientX - active.startX;
    const requested = active.startWidth + (active.panel === "sidebar" ? physicalDelta : -physicalDelta);
    changePanelWidth(active.panel, requested, false);
  }

  function handleSeparatorKey(panel: WorkspacePanel, event: ReactKeyboardEvent<HTMLDivElement>) {
    const current = panel === "sidebar" ? layout.sidebarWidth : layout.previewWidth;
    const bounds = workspacePanelBounds(layout, panel);
    let requested: number | null = null;
    if (event.key === "ArrowLeft") requested = current - 10;
    else if (event.key === "ArrowRight") requested = current + 10;
    else if (event.key === "Home") requested = bounds.min;
    else if (event.key === "End") requested = bounds.max;
    if (requested === null) return;
    event.preventDefault();
    changePanelWidth(panel, requested, true);
  }

  function separator(panel: WorkspacePanel, controls: string) {
    const width = panel === "sidebar" ? layout.sidebarWidth : layout.previewWidth;
    const bounds = workspacePanelBounds(layout, panel);
    const enabled = panel === "sidebar" ? layout.sidebarResizable : layout.previewResizable;
    return <div
      key={`${panel}-resizer`}
      className={`workspace-resizer workspace-${panel}-resizer${activePanel === panel ? " is-resizing" : ""}`}
      role="separator"
      aria-label={panel === "sidebar" ? t("调整文件导航宽度") : t("调整预览宽度")}
      aria-orientation="vertical"
      aria-controls={controls}
      aria-valuemin={bounds.min}
      aria-valuemax={bounds.max}
      aria-valuenow={width}
      aria-disabled={!enabled}
      tabIndex={enabled ? 0 : -1}
      onKeyDown={(event) => handleSeparatorKey(panel, event)}
      onPointerDown={(event) => startPointer(panel, event)}
      onPointerMove={movePointer}
      onPointerUp={(event) => finishPointer(event, false)}
      onPointerCancel={(event) => finishPointer(event, true)}
      onLostPointerCapture={(event) => {
        const active = activeResizeRef.current;
        if (!active || active.panel !== panel || active.pointerId !== event.pointerId) return;
        activeResizeRef.current = null;
        setActivePanel(null);
        setPreference(active.startPreference);
      }}
    />;
  }

  const style = {
    "--workspace-sidebar-width": `${layout.sidebarWidth}px`,
    "--workspace-preview-width": `${layout.previewWidth}px`,
    "--workspace-narrow-sidebar-height": narrowSidebarExpanded ? "min(220px, 28vh)" : "38px",
  } as CSSProperties;
  const sidebarContent = layout.mode === "narrow" && sidebarVisible
    ? <details
        className="workspace-narrow-sidebar"
        open={narrowSidebarExpanded}
        onToggle={(event) => setNarrowSidebarExpanded(event.currentTarget.open)}
      >
        <summary>{t("仓库文件")}</summary>
        {sidebar}
      </details>
    : sidebar;

  return <section
    ref={rootRef}
    id={active ? "workspace-content" : undefined}
    className={`workspace resizable-workspace${className ? ` ${className}` : ""}`}
    aria-label={t("RepoPress 编辑工作区")}
    tabIndex={-1}
    data-layout={layout.mode}
    data-sidebar-visible={sidebarVisible ? "true" : "false"}
    data-preview-visible={previewVisible ? "true" : "false"}
    data-inspector-position={inspectorPosition}
    style={style}
  >
    <div key="sidebar-slot" id="workspace-sidebar-slot" className="workspace-slot workspace-sidebar-slot" hidden={!sidebarVisible}>{sidebarContent}</div>
    {sidebarVisible && layout.mode !== "narrow" && separator("sidebar", "workspace-sidebar-slot")}
    <div key="editor-slot" id="workspace-editor-slot" className="workspace-slot workspace-editor-slot">{editor}</div>
    {previewVisible && layout.mode === "wide" && separator("preview", "workspace-preview-slot")}
    <div key="preview-slot" id="workspace-preview-slot" className="workspace-slot workspace-preview-slot" hidden={!previewVisible}>{preview}</div>
    <div
      key="inspector-slot"
      id="workspace-inspector-slot"
      className="workspace-slot workspace-inspector-slot"
      hidden={!inspectorShown}
      style={inspectorPosition === "docked" ? { gridColumn: "-2 / -1" } : undefined}
    >{inspector}</div>
  </section>;
}
