import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { MetadataInspector } from "./MetadataInspector";

let root: Root; let host: HTMLDivElement;
beforeAll(() => { Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true }); });
afterEach(() => { root?.unmount(); host?.remove(); });
function render(props: Parameters<typeof MetadataInspector>[0]) { host = document.createElement("div"); document.body.append(host); root = createRoot(host); act(() => root.render(createElement(MetadataInspector, props))); }
function button(label: string) { const result = [...host.querySelectorAll("button")].find((item) => item.textContent === label); if (!result) throw new Error(`missing ${label}`); return result as HTMLButtonElement; }

describe("MetadataInspector", () => {
  it("generates its report only on request and sends an exact buffer snapshot to the field locator", () => {
    const onLocateField = vi.fn(); const value = "---\ntitle: \"\"\ndescription: \"\"\n---\nBody";
    render({ value, onLocateField });
    expect(host.textContent).not.toContain("缺少标题");
    act(() => button("生成本地报告").click());
    expect(host.textContent).toContain("缺少标题");
    act(() => button("打开对应字段").click());
    expect(onLocateField).toHaveBeenCalledWith("title", value);
  });

  it("routes structural issues to their read-only warning and expires actions after editing", () => {
    const onLocateField = vi.fn(); const malformed = "---\ntitle: [bad]\n---\nBody";
    render({ value: malformed, onLocateField });
    act(() => button("生成本地报告").click());
    act(() => button("打开对应字段").click());
    expect(onLocateField).toHaveBeenCalledWith("title", malformed);
    act(() => root.render(createElement(MetadataInspector, { value: `${malformed}\nchanged`, onLocateField })));
    expect(host.querySelectorAll("button")).toHaveLength(1);
  });

  it("does not create a report while read-only", () => {
    render({ value: "plain", disabled: true, onLocateField: vi.fn() });
    expect(button("生成本地报告").disabled).toBe(true);
  });
});
