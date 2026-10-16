export const WORKSPACE_LAYOUT_STORAGE_KEY = "repopress.workspace.layout.v1";

export const WORKSPACE_LAYOUT_LIMITS = {
  sidebar: { default: 250, min: 190, max: 360 },
  preview: { default: 340, min: 260, max: 600 },
  editorMin: 360,
  separator: 10,
  wideBreakpoint: 900,
  narrowBreakpoint: 600,
} as const;

export type WorkspacePanel = "sidebar" | "preview";
export type WorkspaceLayoutMode = "wide" | "compact" | "narrow";

export interface WorkspaceLayoutPreference {
  sidebarWidth: number;
  previewWidth: number;
}

export interface WorkspaceLayout {
  mode: WorkspaceLayoutMode;
  sidebarWidth: number;
  previewWidth: number;
  editorWidth: number;
  sidebarResizable: boolean;
  previewResizable: boolean;
}

export const DEFAULT_WORKSPACE_LAYOUT: WorkspaceLayoutPreference = {
  sidebarWidth: WORKSPACE_LAYOUT_LIMITS.sidebar.default,
  previewWidth: WORKSPACE_LAYOUT_LIMITS.preview.default,
};

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, Math.round(value)));
}

export function normalizeWorkspaceLayoutPreference(value: unknown): WorkspaceLayoutPreference {
  const record = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const sidebarWidth = finiteNumber(record.sidebarWidth);
  const previewWidth = finiteNumber(record.previewWidth);
  return {
    sidebarWidth: sidebarWidth === null
      ? DEFAULT_WORKSPACE_LAYOUT.sidebarWidth
      : clamp(sidebarWidth, WORKSPACE_LAYOUT_LIMITS.sidebar.min, WORKSPACE_LAYOUT_LIMITS.sidebar.max),
    previewWidth: previewWidth === null
      ? DEFAULT_WORKSPACE_LAYOUT.previewWidth
      : clamp(previewWidth, WORKSPACE_LAYOUT_LIMITS.preview.min, WORKSPACE_LAYOUT_LIMITS.preview.max),
  };
}

export function readWorkspaceLayoutPreference(storage?: Pick<Storage, "getItem"> | null): WorkspaceLayoutPreference {
  if (!storage) return DEFAULT_WORKSPACE_LAYOUT;
  try {
    const raw = storage.getItem(WORKSPACE_LAYOUT_STORAGE_KEY);
    return raw === null ? DEFAULT_WORKSPACE_LAYOUT : normalizeWorkspaceLayoutPreference(JSON.parse(raw));
  } catch {
    return DEFAULT_WORKSPACE_LAYOUT;
  }
}

export function writeWorkspaceLayoutPreference(
  preference: WorkspaceLayoutPreference,
  storage?: Pick<Storage, "setItem"> | null,
): void {
  if (!storage) return;
  const normalized = normalizeWorkspaceLayoutPreference(preference);
  try {
    // This key intentionally stores only two numeric presentation values. It
    // must never acquire repository, article, or filesystem identifiers.
    storage.setItem(WORKSPACE_LAYOUT_STORAGE_KEY, JSON.stringify({
      sidebarWidth: normalized.sidebarWidth,
      previewWidth: normalized.previewWidth,
    }));
  } catch {
    // Layout persistence is a convenience; the workspace remains usable when
    // browser storage is disabled or full.
  }
}

export function workspaceLayoutMode(containerWidth: number): WorkspaceLayoutMode {
  if (containerWidth < WORKSPACE_LAYOUT_LIMITS.narrowBreakpoint) return "narrow";
  if (containerWidth < WORKSPACE_LAYOUT_LIMITS.wideBreakpoint) return "compact";
  return "wide";
}

export function calculateWorkspaceLayout({
  containerWidth,
  sidebarVisible,
  previewVisible,
  preference,
}: {
  containerWidth: number;
  sidebarVisible: boolean;
  previewVisible: boolean;
  preference: WorkspaceLayoutPreference;
}): WorkspaceLayout {
  const safeWidth = Math.max(0, Math.floor(Number.isFinite(containerWidth) ? containerWidth : 0));
  const mode = workspaceLayoutMode(safeWidth);
  const preferred = normalizeWorkspaceLayoutPreference(preference);

  if (mode === "narrow") {
    return {
      mode,
      sidebarWidth: sidebarVisible ? safeWidth : 0,
      previewWidth: previewVisible ? safeWidth : 0,
      editorWidth: safeWidth,
      sidebarResizable: false,
      previewResizable: false,
    };
  }

  if (mode === "compact") {
    const separatorWidth = sidebarVisible ? WORKSPACE_LAYOUT_LIMITS.separator : 0;
    const maxSidebar = Math.max(0, safeWidth - separatorWidth - WORKSPACE_LAYOUT_LIMITS.editorMin);
    const sidebarWidth = sidebarVisible
      ? clamp(preferred.sidebarWidth, Math.min(WORKSPACE_LAYOUT_LIMITS.sidebar.min, maxSidebar), Math.min(WORKSPACE_LAYOUT_LIMITS.sidebar.max, maxSidebar))
      : 0;
    return {
      mode,
      sidebarWidth,
      previewWidth: previewVisible ? safeWidth - sidebarWidth - separatorWidth : 0,
      editorWidth: safeWidth - sidebarWidth - separatorWidth,
      sidebarResizable: sidebarVisible && maxSidebar >= WORKSPACE_LAYOUT_LIMITS.sidebar.min,
      previewResizable: false,
    };
  }

  const separatorCount = Number(sidebarVisible) + Number(previewVisible);
  const available = Math.max(0, safeWidth - separatorCount * WORKSPACE_LAYOUT_LIMITS.separator);
  let sidebarWidth = sidebarVisible ? preferred.sidebarWidth : 0;
  let previewWidth = previewVisible ? preferred.previewWidth : 0;
  let overflow = Math.max(0, sidebarWidth + previewWidth + WORKSPACE_LAYOUT_LIMITS.editorMin - available);

  if (previewVisible && overflow > 0) {
    const reduction = Math.min(overflow, Math.max(0, previewWidth - WORKSPACE_LAYOUT_LIMITS.preview.min));
    previewWidth -= reduction;
    overflow -= reduction;
  }
  if (sidebarVisible && overflow > 0) {
    const reduction = Math.min(overflow, Math.max(0, sidebarWidth - WORKSPACE_LAYOUT_LIMITS.sidebar.min));
    sidebarWidth -= reduction;
    overflow -= reduction;
  }
  // The wide breakpoint is above the sum of all minimums. This final guard
  // also makes the function safe if callers temporarily report a stale width.
  if (overflow > 0 && previewVisible) {
    const reduction = Math.min(overflow, previewWidth);
    previewWidth -= reduction;
    overflow -= reduction;
  }
  if (overflow > 0 && sidebarVisible) sidebarWidth = Math.max(0, sidebarWidth - overflow);

  return {
    mode,
    sidebarWidth,
    previewWidth,
    editorWidth: Math.max(0, available - sidebarWidth - previewWidth),
    sidebarResizable: sidebarVisible && available - previewWidth - WORKSPACE_LAYOUT_LIMITS.editorMin >= WORKSPACE_LAYOUT_LIMITS.sidebar.min,
    previewResizable: previewVisible && available - sidebarWidth - WORKSPACE_LAYOUT_LIMITS.editorMin >= WORKSPACE_LAYOUT_LIMITS.preview.min,
  };
}

export function workspacePanelBounds(layout: WorkspaceLayout, panel: WorkspacePanel): { min: number; max: number } {
  if (panel === "sidebar") {
    const max = layout.mode === "compact"
      ? layout.sidebarWidth + Math.max(0, layout.editorWidth - WORKSPACE_LAYOUT_LIMITS.editorMin)
      : layout.sidebarWidth + Math.max(0, layout.editorWidth - WORKSPACE_LAYOUT_LIMITS.editorMin);
    return {
      min: Math.min(WORKSPACE_LAYOUT_LIMITS.sidebar.min, max),
      max: Math.min(WORKSPACE_LAYOUT_LIMITS.sidebar.max, max),
    };
  }
  const max = layout.previewWidth + Math.max(0, layout.editorWidth - WORKSPACE_LAYOUT_LIMITS.editorMin);
  return {
    min: Math.min(WORKSPACE_LAYOUT_LIMITS.preview.min, max),
    max: Math.min(WORKSPACE_LAYOUT_LIMITS.preview.max, max),
  };
}

export function resizeWorkspacePanel(
  preference: WorkspaceLayoutPreference,
  layout: WorkspaceLayout,
  panel: WorkspacePanel,
  requestedWidth: number,
): WorkspaceLayoutPreference {
  const bounds = workspacePanelBounds(layout, panel);
  const width = clamp(requestedWidth, bounds.min, bounds.max);
  return panel === "sidebar"
    ? { ...preference, sidebarWidth: width }
    : { ...preference, previewWidth: width };
}
