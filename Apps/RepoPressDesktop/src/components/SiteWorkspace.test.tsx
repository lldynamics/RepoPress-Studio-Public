import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { RepositorySessionSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { SiteWorkspace, type SiteWorkspaceProps } from "./SiteWorkspace";

let root: Root | null = null;
let container: HTMLDivElement | null = null;
const repository: RepositorySessionSnapshot = {
  sessionId: "session-1", rootPath: "/a/very/long/site/root/with a literal path", displayName: "磁带站点", siteKind: "hugo",
  contentRoot: "content", isGitRepository: true, warnings: [],
};

beforeAll(() => {
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

afterEach(() => {
  if (root) act(() => root?.unmount());
  root = null;
  container?.remove();
  container = null;
  vi.unstubAllGlobals();
});

function mount(overrides: Partial<SiteWorkspaceProps> = {}, locale: "zh-CN" | "en-US" = "zh-CN") {
  const props: SiteWorkspaceProps = {
    repository, profileName: "登记名称", busy: false, canCheck: true, canManageSites: true,
    onChooseRepository: vi.fn(), onCheck: vi.fn(), onPublish: vi.fn(), onManageSites: vi.fn(), ...overrides,
  };
  let nextFrame = 0;
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => { nextFrame += 1; callback(0); return nextFrame; });
  vi.stubGlobal("cancelAnimationFrame", vi.fn());
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  act(() => root?.render(createElement(I18nProvider, { locale, children: createElement(SiteWorkspace, props) })));
  return props;
}

function button(label: string): HTMLButtonElement {
  const match = [...(container?.querySelectorAll("button") ?? [])].find((item) => item.textContent === label);
  if (!match) throw new Error(`missing button ${label}`);
  return match;
}

describe("SiteWorkspace", () => {
  it("renders the selected site literally and routes the three actions", () => {
    const props = mount();
    expect(container?.textContent).toContain("登记名称");
    expect(container?.textContent).toContain(repository.rootPath);
    expect(container?.textContent).toContain("hugo");
    expect(props.onCheck).not.toHaveBeenCalled();
    expect(props.onPublish).not.toHaveBeenCalled();
    expect(props.onManageSites).not.toHaveBeenCalled();
    act(() => button("打开站点检查").click());
    act(() => button("打开发布中心").click());
    act(() => button("管理已保存站点").click());
    expect(props.onCheck).toHaveBeenCalledOnce();
    expect(props.onPublish).toHaveBeenCalledOnce();
    expect(props.onManageSites).toHaveBeenCalledOnce();
  });

  it("disables actions at their capability boundaries and offers repository selection", () => {
    const choose = vi.fn();
    const props = mount({ repository: null, canCheck: false, canManageSites: false, onChooseRepository: choose });
    expect(button("选择仓库").disabled).toBe(false);
    expect(button("打开站点检查").disabled).toBe(true);
    expect(button("打开发布中心").disabled).toBe(true);
    expect(button("管理已保存站点").disabled).toBe(true);
    act(() => button("选择仓库").click());
    expect(choose).toHaveBeenCalledOnce();
    expect(container?.textContent).toContain("尚未选择站点仓库。");
    expect(props.onCheck).not.toHaveBeenCalled();
  });

  it("translates the workspace and retains heading focus through prop and locale changes", () => {
    mount({}, "en-US");
    expect(container?.textContent).toContain("Site workspace");
    expect(container?.textContent).toContain("Open site check");
    const heading = container?.querySelector("h1");
    expect(document.activeElement).toBe(heading);
    act(() => root?.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(SiteWorkspace, { repository: { ...repository, displayName: "更新站点" }, profileName: null, busy: false, canCheck: true, canManageSites: true, onChooseRepository: vi.fn(), onCheck: vi.fn(), onPublish: vi.fn(), onManageSites: vi.fn() }) })));
    expect(document.activeElement).toBe(heading);
    expect(container?.textContent).toContain("更新站点");
  });

  it("can leave initial focus to a concurrently opening dialog", () => {
    mount({ focusOnMount: false });
    expect(document.activeElement).not.toBe(container?.querySelector("h1"));
  });
});
