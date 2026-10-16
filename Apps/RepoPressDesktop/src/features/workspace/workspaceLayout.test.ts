import { describe, expect, it, vi } from "vitest";
import {
  DEFAULT_WORKSPACE_LAYOUT,
  WORKSPACE_LAYOUT_STORAGE_KEY,
  calculateWorkspaceLayout,
  normalizeWorkspaceLayoutPreference,
  readWorkspaceLayoutPreference,
  resizeWorkspacePanel,
  writeWorkspaceLayoutPreference,
} from "./workspaceLayout";

describe("workspace layout preferences", () => {
  it("defaults invalid fields and clamps finite widths from versioned storage", () => {
    expect(normalizeWorkspaceLayoutPreference(null)).toEqual(DEFAULT_WORKSPACE_LAYOUT);
    expect(normalizeWorkspaceLayoutPreference({ sidebarWidth: "280", previewWidth: Number.NaN })).toEqual(DEFAULT_WORKSPACE_LAYOUT);
    expect(normalizeWorkspaceLayoutPreference({ sidebarWidth: -20, previewWidth: 50_000 })).toEqual({
      sidebarWidth: 190,
      previewWidth: 600,
    });

    const storage = { getItem: vi.fn(() => "not-json") };
    expect(readWorkspaceLayoutPreference(storage)).toEqual(DEFAULT_WORKSPACE_LAYOUT);
    expect(storage.getItem).toHaveBeenCalledWith(WORKSPACE_LAYOUT_STORAGE_KEY);
  });

  it("keeps storage best-effort and writes only numeric layout values", () => {
    expect(readWorkspaceLayoutPreference({ getItem: () => { throw new Error("blocked"); } })).toEqual(DEFAULT_WORKSPACE_LAYOUT);
    expect(() => writeWorkspaceLayoutPreference(DEFAULT_WORKSPACE_LAYOUT, { setItem: () => { throw new Error("full"); } })).not.toThrow();

    const setItem = vi.fn();
    writeWorkspaceLayoutPreference({ sidebarWidth: 275.4, previewWidth: 410.7 }, { setItem });
    expect(setItem).toHaveBeenCalledWith(WORKSPACE_LAYOUT_STORAGE_KEY, JSON.stringify({
      sidebarWidth: 275,
      previewWidth: 411,
    }));
  });
});

describe("workspace layout calculation", () => {
  it("limits side panels before allowing the editor below its minimum", () => {
    expect(calculateWorkspaceLayout({
      containerWidth: 920,
      sidebarVisible: true,
      previewVisible: true,
      preference: { sidebarWidth: 360, previewWidth: 600 },
    })).toMatchObject({
      mode: "wide",
      sidebarWidth: 280,
      previewWidth: 260,
      editorWidth: 360,
    });
  });

  it("uses two columns with preview below in compact windows and stacks narrow windows", () => {
    expect(calculateWorkspaceLayout({
      containerWidth: 800,
      sidebarVisible: true,
      previewVisible: true,
      preference: DEFAULT_WORKSPACE_LAYOUT,
    })).toEqual({
      mode: "compact",
      sidebarWidth: 250,
      previewWidth: 540,
      editorWidth: 540,
      sidebarResizable: true,
      previewResizable: false,
    });
    expect(calculateWorkspaceLayout({
      containerWidth: 480,
      sidebarVisible: true,
      previewVisible: true,
      preference: DEFAULT_WORKSPACE_LAYOUT,
    })).toEqual({
      mode: "narrow",
      sidebarWidth: 480,
      previewWidth: 480,
      editorWidth: 480,
      sidebarResizable: false,
      previewResizable: false,
    });
  });

  it("returns remembered preferences when a hidden panel is restored", () => {
    const preference = { sidebarWidth: 320, previewWidth: 460 };
    const hidden = calculateWorkspaceLayout({ containerWidth: 1_300, sidebarVisible: false, previewVisible: true, preference });
    expect(hidden.sidebarWidth).toBe(0);
    expect(hidden.previewWidth).toBe(460);

    const restored = calculateWorkspaceLayout({ containerWidth: 1_300, sidebarVisible: true, previewVisible: true, preference });
    expect(restored.sidebarWidth).toBe(320);
    expect(restored.previewWidth).toBe(460);
    expect(restored.editorWidth).toBe(500);
  });

  it("clamps resize requests to the live editor-safe bounds", () => {
    const layout = calculateWorkspaceLayout({
      containerWidth: 1_000,
      sidebarVisible: true,
      previewVisible: true,
      preference: DEFAULT_WORKSPACE_LAYOUT,
    });
    expect(resizeWorkspacePanel(DEFAULT_WORKSPACE_LAYOUT, layout, "sidebar", 999).sidebarWidth).toBe(280);
    expect(resizeWorkspacePanel(DEFAULT_WORKSPACE_LAYOUT, layout, "preview", -1).previewWidth).toBe(260);
  });
});
