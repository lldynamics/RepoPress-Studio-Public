import { act, createElement, useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WorkspaceInspector, type WorkspaceInspectorTab } from "./WorkspaceInspector";

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;

function StatefulPanel({ label }: { label: string }) {
  const [count, setCount] = useState(0);
  return createElement("button", { type: "button", "data-testid": `panel-${label}`, onClick: () => setCount((current) => current + 1) }, `${label} ${count}`);
}

function InspectorHarness({ onClose = () => undefined, disabled = false, contents }: {
  onClose?: () => void;
  disabled?: boolean;
  contents?: ReactNode[];
}) {
  const [activeTab, setActiveTab] = useState("writing");
  const tabs: WorkspaceInspectorTab[] = [
    { id: "writing", label: "写作", content: contents?.[0] ?? createElement(StatefulPanel, { label: "写作" }) },
    { id: "metadata", label: "属性与 SEO", content: contents?.[1] ?? createElement(StatefulPanel, { label: "属性" }) },
    { id: "outline", label: "大纲", content: contents?.[2] ?? createElement(StatefulPanel, { label: "大纲" }) },
  ];
  return createElement(WorkspaceInspector, { tabs, activeTab, onSelectTab: setActiveTab, onClose, disabled });
}

function tabs() {
  return [...host.querySelectorAll<HTMLButtonElement>("[role='tab']")];
}

describe("WorkspaceInspector", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.restoreAllMocks();
  });

  it("renders accessible tabs and keeps every panel mounted while switching", () => {
    act(() => root.render(createElement(InspectorHarness)));
    const panels = [...host.querySelectorAll<HTMLElement>("[role='tabpanel']")];
    expect(host.querySelector("[aria-label='文章检查器']")).not.toBeNull();
    expect(host.querySelector("[role='tablist']")).not.toBeNull();
    expect(tabs()).toHaveLength(3);
    expect(panels).toHaveLength(3);
    expect(panels[0].hidden).toBe(false);
    expect(panels[1].hidden).toBe(true);

    const writingState = host.querySelector<HTMLButtonElement>("[data-testid='panel-写作']")!;
    act(() => writingState.click());
    expect(writingState.textContent).toBe("写作 1");
    act(() => tabs()[1].click());
    expect(panels[0].hidden).toBe(true);
    expect(panels[1].hidden).toBe(false);
    expect(host.querySelector("[data-testid='panel-写作']")).toBe(writingState);
    act(() => tabs()[0].click());
    expect(writingState.textContent).toBe("写作 1");
  });

  it("selects and focuses tabs with arrows, Home, and End", () => {
    act(() => root.render(createElement(InspectorHarness)));
    tabs()[0].focus();

    act(() => tabs()[0].dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })));
    expect(tabs()[1].getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(tabs()[1]);

    act(() => tabs()[1].dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true, cancelable: true })));
    expect(tabs()[2].getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(tabs()[2]);

    act(() => tabs()[2].dispatchEvent(new KeyboardEvent("keydown", { key: "Home", bubbles: true, cancelable: true })));
    expect(tabs()[0].getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(tabs()[0]);

    act(() => tabs()[0].dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true, cancelable: true })));
    expect(tabs()[2].getAttribute("aria-selected")).toBe("true");
  });

  it("calls the explicit close action and disables all tab actions when requested", () => {
    const onClose = vi.fn();
    act(() => root.render(createElement(InspectorHarness, { onClose })));
    act(() => host.querySelector<HTMLButtonElement>("[aria-label='关闭文章检查器']")!.click());
    expect(onClose).toHaveBeenCalledTimes(1);

    act(() => root.render(createElement(InspectorHarness, { onClose, disabled: true })));
    expect(tabs().every((tab) => tab.disabled)).toBe(true);
    expect(host.querySelector<HTMLButtonElement>("[aria-label='关闭文章检查器']")!.disabled).toBe(true);
  });
});
