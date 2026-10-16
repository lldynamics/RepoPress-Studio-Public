import { act, createElement, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { getDrawerFocusableElements, useDrawerFocus } from "./drawerFocus";

let root: Root | null = null;
let container: HTMLDivElement | null = null;

beforeAll(() => { (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true; });

function DrawerHarness({ open, onClose }: { open: boolean; onClose: () => void }) {
  const drawer = useRef<HTMLElement>(null);
  useDrawerFocus(open, drawer, onClose);
  return createElement("main", null,
    createElement("button", { id: "trigger" }, "Open"),
    createElement("section", { id: "drawer", ref: drawer, tabIndex: -1 },
      createElement("button", { id: "first" }, "First"),
      createElement("button", { id: "disabled", disabled: true }, "Disabled"),
      createElement("div", { hidden: true }, createElement("button", { id: "hidden" }, "Hidden")),
      createElement("div", { "aria-hidden": "true" }, createElement("button", { id: "aria-hidden" }, "Hidden from AT")),
      createElement("div", { inert: true }, createElement("button", { id: "inert" }, "Inert")),
      createElement("div", { role: "tabpanel", hidden: true }, createElement("button", { id: "hidden-tab" }, "Hidden tab")),
      createElement("button", { id: "last" }, "Last"),
    ),
    createElement("button", { id: "background" }, "Background"),
  );
}

function SwitchingDrawerHarness({ active }: { active: "a" | "b" | null }) {
  const drawerA = useRef<HTMLElement>(null);
  const drawerB = useRef<HTMLElement>(null);
  useDrawerFocus(active === "a", drawerA, () => undefined);
  useDrawerFocus(active === "b", drawerB, () => undefined);
  return createElement("main", null,
    createElement("button", { id: "switch-trigger" }, "Open"),
    createElement("aside", { id: "drawer-a", ref: drawerA, tabIndex: -1, "aria-hidden": active !== "a", inert: active !== "a" },
      createElement("button", { id: "drawer-a-first" }, "A"),
    ),
    createElement("aside", { id: "drawer-b", ref: drawerB, tabIndex: -1, "aria-hidden": active !== "b", inert: active !== "b" },
      createElement("button", { id: "drawer-b-first" }, "B"),
    ),
    createElement("button", { id: "switch-background" }, "Background"),
  );
}

function mount(open: boolean, onClose = vi.fn()) {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  act(() => root?.render(createElement(DrawerHarness, { open, onClose })));
  return onClose;
}

async function render(open: boolean, onClose: () => void) {
  await act(async () => {
    root?.render(createElement(DrawerHarness, { open, onClose }));
    await Promise.resolve();
    await Promise.resolve();
  });
}

function byId<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id) as T | null;
  if (!element) throw new Error(`missing #${id}`);
  return element;
}

afterEach(() => {
  if (root) act(() => root?.unmount());
  root = null;
  container?.remove();
  container = null;
});

describe("drawer focus", () => {
  it("filters disabled, inert, hidden, aria-hidden, and hidden tab panel controls", () => {
    mount(false);
    const ids = getDrawerFocusableElements(byId("drawer")).map((element) => element.id);
    expect(ids).toEqual(["first", "last"]);
  });

  it("loops Tab at both ends and closes on Escape", async () => {
    const onClose = mount(false);
    byId<HTMLButtonElement>("trigger").focus();
    await render(true, onClose);
    const first = byId<HTMLButtonElement>("first");
    const last = byId<HTMLButtonElement>("last");
    expect(document.activeElement).toBe(first);

    last.focus();
    const forward = new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
    last.dispatchEvent(forward);
    expect(forward.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(first);

    const backward = new KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true });
    first.dispatchEvent(backward);
    expect(backward.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(last);

    const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    last.dispatchEvent(escape);
    expect(escape.defaultPrevented).toBe(true);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("restores exact inert values and only restores focus to a safe trigger", async () => {
    const onClose = mount(false);
    const trigger = byId<HTMLButtonElement>("trigger");
    const background = byId<HTMLButtonElement>("background");
    background.inert = true;
    trigger.focus();
    await render(true, onClose);
    expect(trigger.inert).toBe(true);
    expect(background.inert).toBe(true);

    await render(false, onClose);
    expect(trigger.inert).toBe(false);
    expect(background.inert).toBe(true);
    expect(document.activeElement).toBe(trigger);

    trigger.disabled = true;
    await render(true, onClose);
    await render(false, onClose);
    expect(document.activeElement).toBe(document.body);
  });

  it("does not restore stale inert state when switching directly between sibling drawers", async () => {
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
    await act(async () => {
      root?.render(createElement(SwitchingDrawerHarness, { active: null }));
      await Promise.resolve();
    });
    byId<HTMLButtonElement>("switch-trigger").focus();

    await act(async () => {
      root?.render(createElement(SwitchingDrawerHarness, { active: "a" }));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(document.activeElement).toBe(byId("drawer-a-first"));

    await act(async () => {
      root?.render(createElement(SwitchingDrawerHarness, { active: "b" }));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(byId<HTMLElement>("drawer-a").hasAttribute("inert") || Boolean(byId<HTMLElement>("drawer-a").inert)).toBe(true);
    expect(byId<HTMLElement>("drawer-b").hasAttribute("inert") || Boolean(byId<HTMLElement>("drawer-b").inert)).toBe(false);
    expect(document.activeElement).toBe(byId("drawer-b-first"));
  });
});
