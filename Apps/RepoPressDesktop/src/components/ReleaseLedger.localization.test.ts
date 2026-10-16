import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import { I18nProvider } from "../i18n/i18n";
import { ReleaseLedgerPanel, type ReleaseLedgerPanelProps } from "./ReleaseLedgerPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const entries = Array.from({ length: 51 }, (_, index) => ({ source: "gitPush" as const, recordId: `literal-{page}-${index}`, revision: 1, operation: "push" as const, branch: "设置", targetBranch: null, expectedSha: "a".repeat(40), remoteUrl: "https://example.test/设置.git", startedAtEpochMs: 1_000, checkedAtEpochMs: 2_000, status: "pushVerified" as const }));
const snapshot: ReleaseLedgerSnapshot = { sessionId: "session", entries, partialSources: ["remoteReview"], warnings: ["设置", "<b>{total}</b>"], summary: { total: 51, verifiedPushes: 51, verifiedReviews: 0, needsAttention: 0 } };
let host: HTMLDivElement; let root: Root; let props: ReleaseLedgerPanelProps;
let get: ReturnType<typeof vi.fn<(session: string) => Promise<ReleaseLedgerSnapshot>>>;
function render(locale: "zh-CN" | "en-US", update: Partial<ReleaseLedgerPanelProps> = {}) {
  props = { ...props, ...update };
  act(() => root.render(createElement(I18nProvider, { locale, children: createElement(ReleaseLedgerPanel, props) })));
}
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label)!; }
async function click(label: string) { await act(async () => button(label).click()); }

beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  get = vi.fn(async () => snapshot);
  props = { gateway: { getReleaseLedger: get }, sessionId: "session", enabled: true, onOpenSource: vi.fn() };
});
afterEach(() => { act(() => root.unmount()); host.remove(); });

describe("Release ledger live localization", () => {
  it("keeps its page and literal evidence through language changes without loading or observing again", async () => {
    render("zh-CN"); await settle(); await click("下一页");
    const record = host.querySelector("article")!;
    expect(record.textContent).toContain(entries[50].recordId);
    render("en-US");
    expect(host.textContent).toContain("Page 2 / 2 (up to 50 records per page)");
    expect(host.textContent).toContain("Some sources could not be read: PR/MR records.");
    expect(host.textContent).toContain("does not mean merged or deployed");
    expect(host.textContent).toContain(entries[50].branch); expect(host.textContent).toContain(entries[50].expectedSha);
    expect(host.textContent).toContain("<b>{total}</b>"); expect(host.querySelector("b")).toBeNull();
    expect(host.textContent).toContain(new Date(2_000).toLocaleString("en-US"));
    expect(host.querySelector("article")).toBe(record); expect(get).toHaveBeenCalledTimes(1);
    await click("View Push records"); expect(props.onOpenSource).toHaveBeenCalledWith("gitPush");
    render("zh-CN"); expect(host.textContent).toContain("第 2 / 2 页（每页最多 50 条）");
    expect(get).toHaveBeenCalledTimes(1);
  });

  it("preserves a pending read and translates the local generic error without exposing the backend error", async () => {
    let resolve!: (value: ReleaseLedgerSnapshot) => void;
    get.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
    render("zh-CN"); render("en-US");
    expect(host.textContent).toContain("Reading the local release ledger…"); expect(get).toHaveBeenCalledTimes(1);
    await act(async () => resolve(snapshot));
    expect(host.textContent).toContain("Visible ledger summary: 51 records");
    get.mockRejectedValueOnce(new Error("private backend message /private/secret"));
    await click("Refresh ledger"); expect(host.textContent).toContain("Unable to read the release ledger. Try again later.");
    expect(host.textContent).not.toContain("private backend");
    render("zh-CN"); expect(host.textContent).toContain("无法读取发布台账，请稍后重试。"); expect(get).toHaveBeenCalledTimes(2);
  });

  it("localizes capacity and partial scope without treating an empty partial ledger as complete", async () => {
    get.mockResolvedValueOnce({ sessionId: "session", entries: [], warnings: ["设置"], partialSources: ["gitPush"],
      summary: { total: 0, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0, rollbackTransactions: 0, historicalCandidateObservations: 0, unresolvedRollbackTransactions: 0 },
      rollbackDiagnostics: { status: "available", capacity: "available", globalRecords: 1, localRecords: 0, localUnresolved: 0, payloadBytes: 100, remainingPayloadBytes: 4_143_004, maxRecords: 200, maxPayloadBytes: 4_194_304, maxRecordBytes: 65_536, reservedObservationBytes: 51_200, scopePartial: true, blockedTargets: [], checkedAtEpochMs: 3_000 } });
    render("en-US"); await settle();
    expect(host.textContent).toContain("Local recovery diagnostics: Available, capacity space available");
    expect(host.textContent).toContain("known target scope is incomplete");
    expect(host.textContent).toContain("does not mean all sources have no records");
    expect(host.textContent).toContain("设置");
    render("zh-CN"); expect(host.textContent).toContain("已知目标范围不完整"); expect(get).toHaveBeenCalledTimes(1);
    render("en-US", { disabled: true }); expect(button("Refresh ledger").disabled).toBe(true); expect(get).toHaveBeenCalledTimes(1);
  });
});
