import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RssGateway, RssOpmlReview } from "../features/rss/contracts";
import { I18nProvider } from "../i18n/i18n";
import { RssOpmlPrivacyDialog } from "./RssOpmlPrivacyDialog";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const source = '<opml version="2.0"><body><outline text="Private" xmlUrl="https://example.com/feed?token=secret"/></body></opml>';
const review: RssOpmlReview = { direction: "import", fingerprint: "fingerprint", totalCount: 1, affectedCount: 1, blockedCount: 0, findings: [{ index: 0, location: "outline[1].@xmlUrl", displayUrl: "https://example.com/feed?token=REDACTED", parameterNames: ["token"], containsUserInfo: false }] };

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }
function gateway(overrides: Partial<RssGateway> = {}) {
  return { reviewOpml: vi.fn(async () => review), executeOpml: vi.fn(async () => ({ opml: null, importedCount: 1, skippedCount: 0, exportedCount: 0, excludedCount: 0 })), ...overrides } as unknown as RssGateway;
}

let host: HTMLDivElement; let root: Root;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });
function button(label: string) { const value = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label); if (!value) throw new Error(`Missing button: ${label}`); return value; }
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
async function input(value: string) { const textarea = host.querySelector<HTMLTextAreaElement>("textarea")!; await act(async () => { Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea, value); textarea.dispatchEvent(new Event("input", { bubbles: true })); }); }
function render(rssGateway: RssGateway, onClose = vi.fn(), onChanged = vi.fn(), locale: "zh-CN" | "en-US" = "zh-CN") { act(() => root.render(<I18nProvider locale={locale}><RssOpmlPrivacyDialog gateway={rssGateway} onClose={onClose} onChanged={onChanged} /></I18nProvider>)); return { onClose, onChanged }; }

beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });

describe("RSS OPML privacy review", () => {
  it("requires an explicit review, invalidates it on edit, and supports cancel", async () => {
    const rssGateway = gateway(); render(rssGateway); await input(source);
    expect(vi.mocked(rssGateway.executeOpml)).not.toHaveBeenCalled();
    await click("审查风险");
    expect(rssGateway.reviewOpml).toHaveBeenCalledWith({ direction: "import", opml: source });
    expect(host.textContent).toContain("token=REDACTED");
    await click("取消审查"); expect(host.textContent).not.toContain("审查结果");
    await click("审查风险"); await input(`${source} `);
    expect(host.textContent).not.toContain("脱敏后执行");
    expect(vi.mocked(rssGateway.executeOpml)).not.toHaveBeenCalled();
  });

  it("executes only the reviewed source and refreshes after a mutating import", async () => {
    const rssGateway = gateway(); const { onChanged } = render(rssGateway); await input(source); await click("审查风险"); await click("脱敏后执行");
    expect(rssGateway.executeOpml).toHaveBeenCalledWith({ direction: "import", opml: source, fingerprint: "fingerprint", action: "redact" });
    expect(onChanged).toHaveBeenCalledTimes(1); expect(host.textContent).toContain("新增 1");
  });

  it("does not expose export text before review and privacy execution", async () => {
    const safeOutput = '<opml version="2.0"><body/></opml>';
    const rssGateway = gateway({ reviewOpml: vi.fn(async () => ({ ...review, direction: "export" as const })), executeOpml: vi.fn(async () => ({ opml: safeOutput, importedCount: 0, skippedCount: 0, exportedCount: 0, excludedCount: 1 })) });
    render(rssGateway); await click("导出 OPML");
    expect(host.querySelector("textarea")).toBeNull(); await click("审查风险"); expect(host.querySelector("textarea")).toBeNull();
    await click("排除风险订阅后执行"); expect(host.querySelector<HTMLTextAreaElement>("textarea")?.value).toBe(safeOutput);
    expect(rssGateway.executeOpml).toHaveBeenCalledWith({ direction: "export", fingerprint: "fingerprint", action: "exclude" });
    render(gateway()); expect(host.querySelector("textarea")).toBeNull(); expect(host.textContent).not.toContain("安全 OPML 已生成");
  });

  it("blocks redaction for user-info findings and ignores a late review after unmount", async () => {
    const pending = deferred<RssOpmlReview>(); const rssGateway = gateway({ reviewOpml: vi.fn(() => pending.promise) }); render(rssGateway); await input(source); await click("审查风险");
    act(() => root.unmount());
    await act(async () => pending.resolve({ ...review, blockedCount: 1, findings: [{ ...review.findings[0], containsUserInfo: true }] }));
    expect(vi.mocked(rssGateway.executeOpml)).not.toHaveBeenCalled();
  });

  it("invalidates an old gateway review response", async () => {
    const pending = deferred<RssOpmlReview>(); const oldGateway = gateway({ reviewOpml: vi.fn(() => pending.promise) }); const nextGateway = gateway();
    render(oldGateway); await input(source); await click("审查风险"); render(nextGateway); await settle();
    expect(host.textContent).toContain("审查风险"); expect(host.textContent).not.toContain("正在审查…");
    await act(async () => pending.resolve(review)); await settle();
    expect(host.textContent).not.toContain("审查结果"); expect(nextGateway.executeOpml).not.toHaveBeenCalled();
  });

  it("shows a bounded message from structured native review errors", async () => {
    const instruction = "审查已过期，请重新审查。";
    render(gateway({ reviewOpml: vi.fn(async () => Promise.reject({ code: "STALE_REVIEW", message: `${instruction}${"x".repeat(600)}` })) }));
    await input(source); await click("审查风险");
    expect(host.querySelector('[role="alert"]')?.textContent).toContain(instruction);
    expect(host.querySelector('[role="alert"]')?.textContent).toHaveLength(500);
  });

  it("localizes the privacy review controls in English", () => {
    render(gateway(), vi.fn(), vi.fn(), "en-US");
    expect(host.textContent).toContain("OPML privacy review"); expect(host.textContent).toContain("Review risks"); expect(host.textContent).toContain("RSS backups do not use this redaction flow");
  });
});
