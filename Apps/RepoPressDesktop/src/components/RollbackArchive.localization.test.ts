import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RollbackArchiveGateway, RollbackArchivePlan, RollbackArchiveResult } from "../contracts/rollbackArchive";
import { I18nProvider } from "../i18n/i18n";
import { RollbackArchivePanel } from "./RollbackArchivePanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const plan: RollbackArchivePlan = {
  planId: "11111111-1111-4111-8111-111111111111", sessionId: "session-1", repositoryPath: "/repo/中文仓库",
  destinationPath: "/tmp/repopress-rollback-证据.json", schemaVersion: 1, recordCount: 2,
  unresolvedCount: 1, historicalObservationCount: 1, byteSize: 4096, sha256: "a".repeat(64),
  createdAtEpochMs: 1_700_000_000_000, expiresAtEpochMs: 1_700_000_300_000,
};
const result: RollbackArchiveResult = { planId: plan.planId, sessionId: plan.sessionId, destinationPath: plan.destinationPath, recordCount: 2, byteSize: 4096, sha256: plan.sha256 };
type Gateway = { [K in keyof RollbackArchiveGateway]: ReturnType<typeof vi.fn> };

let host: HTMLDivElement;
let root: Root;
let gateway: Gateway;

function render(locale: "zh-CN" | "en-US") {
  const child = createElement(RollbackArchivePanel, { gateway: gateway as unknown as RollbackArchiveGateway, sessionId: "session-1", enabled: true });
  act(() => root.render(createElement(I18nProvider, { locale, children: child })));
}
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(text: string) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text); }
async function chooseAndPlan() {
  await act(async () => button("选择归档目的地")!.click());
  await settle();
  await act(async () => button("生成归档计划")!.click());
  await settle();
}

describe("RollbackArchivePanel localization", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(plan.createdAtEpochMs);
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      selectRollbackArchiveDestination: vi.fn(async () => plan.destinationPath),
      planRollbackArchive: vi.fn(async () => plan),
      executeRollbackArchive: vi.fn(async () => result),
      discardRollbackArchive: vi.fn(async () => undefined),
    } as unknown as Gateway;
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("translates controls across zh/en/zh while retaining the selected destination and frozen plan", async () => {
    render("zh-CN");
    await chooseAndPlan();
    expect(host.textContent).toContain("私有回滚证据归档");
    expect(host.textContent).toContain(plan.destinationPath);
    expect(host.textContent).toContain(plan.sha256);
    const calls = gateway.planRollbackArchive.mock.calls.length;

    render("en-US");
    expect(host.querySelector("section")?.getAttribute("aria-label")).toBe("Private rollback evidence archive");
    expect(host.textContent).toContain("Archive plan (one use, up to 5 minutes)");
    expect(host.textContent).toContain(plan.destinationPath);
    expect(host.textContent).toContain(plan.sha256);
    expect(gateway.planRollbackArchive).toHaveBeenCalledTimes(calls);

    render("zh-CN");
    expect(host.textContent).toContain("归档计划（一次性，最多 5 分钟）");
    expect(host.textContent).toContain(plan.destinationPath);
    expect(gateway.planRollbackArchive).toHaveBeenCalledTimes(calls);
  });

  it("localizes controlled errors while preserving cancellation and one-use guards", async () => {
    gateway.selectRollbackArchiveDestination.mockRejectedValueOnce(new Error("native dialog failed"));
    render("zh-CN");
    await act(async () => button("选择归档目的地")!.click());
    await settle();
    render("en-US");
    expect(host.textContent).toContain("Unable to choose an archive destination. Try again later.");
    expect(gateway.planRollbackArchive).not.toHaveBeenCalled();

    gateway.selectRollbackArchiveDestination.mockResolvedValueOnce(plan.destinationPath);
    render("zh-CN");
    await chooseAndPlan();
    const checkbox = host.querySelector<HTMLInputElement>("input[type=checkbox]")!;
    await act(async () => checkbox.click());
    await act(async () => button("明确导出私有回滚证据归档")!.click());
    await settle();
    expect(gateway.executeRollbackArchive).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain(plan.destinationPath);
    expect(host.querySelector<HTMLInputElement>("input[type=checkbox]" )).toBeNull();
    expect(button("明确导出私有回滚证据归档")).toBeUndefined();
  });
});
