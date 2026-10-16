import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ContentHealthSourceSnapshot, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { ImageReferenceReport } from "../contracts/imageReferences";
import { ImageReferenceCheckPanel, type ImageReferenceCheckPanelProps } from "./ImageReferenceCheckPanel";

const start = vi.hoisted(() => vi.fn());
vi.mock("../features/images/imageReferenceAnalysis", () => ({ startImageReferenceAnalysis: start }));
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const repository: RepositorySessionSnapshot = { sessionId: "s1", rootPath: "/repo", displayName: "repo", siteKind: "hugo", contentRoot: "content", isGitRepository: false, warnings: [] };
const images = { images: [], scannedEntries: 0, scannedBytes: 0, omittedFiles: 0, truncated: false, warnings: [] };
const sources: ContentHealthSourceSnapshot = { documents: [], totalFiles: 0, scannedFiles: 0, scannedBytes: 0, omittedFiles: 0, truncated: false, omissions: [], warnings: [] };
const report: ImageReferenceReport = { references: [], scannedDocuments: 7, omittedDocuments: 0, imageCount: 0, imagesWithoutReferences: [], partial: false, truncated: false, warnings: ["报告样本"] };
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
let root: Root | null = null;
let host: HTMLDivElement;
function render(overrides: Partial<ImageReferenceCheckPanelProps> = {}) {
  const props: ImageReferenceCheckPanelProps = { gateway: { inspectContentHealthSources: vi.fn().mockResolvedValue(sources) } as unknown as RepositoryGateway, repository, images, enabled: true, locked: false, selectedImagePath: null, onSelectImage: vi.fn(), ...overrides };
  if (!root) { host = document.createElement("div"); document.body.append(host); root = createRoot(host); }
  act(() => root!.render(createElement(ImageReferenceCheckPanel, props)));
  return props;
}
async function click(label: string) {
  const button = [...host.querySelectorAll("button")].find((item) => item.textContent === label);
  expect(button).toBeTruthy();
  await act(async () => { button!.click(); });
}
afterEach(() => { if (root) act(() => root!.unmount()); root = null; host?.remove(); start.mockReset(); });

describe("ImageReferenceCheckPanel", () => {
  it("requires explicit checking and an enabled image snapshot", async () => {
    const props = render({ images: null });
    await click("检查引用与 Alt");
    expect(props.gateway.inspectContentHealthSources).not.toHaveBeenCalled();
    render({ ...props, images, enabled: false });
    await click("检查引用与 Alt");
    expect(props.gateway.inspectContentHealthSources).not.toHaveBeenCalled();
    expect(start).not.toHaveBeenCalled();
  });

  it("binds sources, inventory, site mapping and current buffer to one scan", async () => {
    start.mockReturnValue({ promise: Promise.resolve(report), cancel: vi.fn() });
    const overlay = { relativePath: "content/a.md", text: "![当前缓冲区](/cover.png)" };
    const props = render({ overlay });
    expect(start).not.toHaveBeenCalled();
    await click("检查引用与 Alt");
    expect(props.gateway.inspectContentHealthSources).toHaveBeenCalledWith("s1");
    expect(start).toHaveBeenCalledWith({ sources, images, repository: { siteKind: "hugo", contentRoot: "content" }, overlay });
    expect(host.textContent).toContain("报告样本");
  });

  it("cancels a pending read and ignores it while the next scan completes", async () => {
    const old = deferred<ContentHealthSourceSnapshot>();
    const read = vi.fn().mockReturnValueOnce(old.promise).mockResolvedValue(sources);
    start.mockReturnValue({ promise: Promise.resolve(report), cancel: vi.fn() });
    render({ gateway: { inspectContentHealthSources: read } as unknown as RepositoryGateway });
    await click("检查引用与 Alt"); await click("取消检查"); await click("检查引用与 Alt");
    expect(start).toHaveBeenCalledTimes(1);
    await act(async () => { old.resolve({ ...sources, totalFiles: 99 }); });
    expect(start).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("报告样本");
  });

  it("invalidates pending analysis when editor content changes", async () => {
    const pending = deferred<ImageReferenceReport>(); const cancel = vi.fn();
    start.mockReturnValue({ promise: pending.promise, cancel });
    const props = render({ overlay: { relativePath: "content/a.md", text: "old" } });
    await click("检查引用与 Alt");
    render({ ...props, overlay: { relativePath: "content/a.md", text: "new" } });
    expect(cancel).toHaveBeenCalledTimes(1);
    await act(async () => { pending.resolve(report); });
    expect(host.textContent).not.toContain("报告样本");
    expect(host.querySelector('[aria-label="图片引用与 Alt 检查"]')?.getAttribute("aria-busy")).toBe("false");
  });

  it("discards old source reads after switching session or replacing inventory", async () => {
    const pending = deferred<ContentHealthSourceSnapshot>();
    const props = render({ gateway: { inspectContentHealthSources: vi.fn().mockReturnValue(pending.promise) } as unknown as RepositoryGateway });
    await click("检查引用与 Alt");
    render({ ...props, repository: { ...repository, sessionId: "s2" }, images: { ...images } });
    await act(async () => { pending.resolve(sources); });
    expect(start).not.toHaveBeenCalled();
  });

  it("shows failure without manufacturing an empty success report and allows retry", async () => {
    start.mockImplementationOnce(() => ({ promise: Promise.reject(new Error("后台不可用")), cancel: vi.fn() }))
      .mockImplementationOnce(() => ({ promise: Promise.resolve(report), cancel: vi.fn() }));
    render(); await click("检查引用与 Alt");
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("后台不可用");
    expect(host.querySelector('[aria-label="图片引用扫描结果"]')).toBeNull();
    await click("检查引用与 Alt"); expect(host.textContent).toContain("报告样本");
  });

  it("terminates analysis when the workbench content unmounts", async () => {
    const pending = deferred<ImageReferenceReport>(); const cancel = vi.fn();
    start.mockReturnValue({ promise: pending.promise, cancel });
    render(); await click("检查引用与 Alt");
    act(() => root!.unmount()); root = null;
    expect(cancel).toHaveBeenCalledTimes(1);
    await act(async () => { pending.resolve(report); });
    expect(host.textContent).toBe("");
  });
});
