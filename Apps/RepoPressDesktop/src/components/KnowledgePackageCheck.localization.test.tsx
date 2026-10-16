import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS,
  KNOWLEDGE_PACKAGE_CHECK_LIMITS,
  type KnowledgePackageCheckGateway,
  type KnowledgePackageCheckReport,
  type KnowledgePackageMemoryPreflight,
} from "../contracts/knowledgePackageCheck";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { KnowledgePackageCheckPanel } from "./KnowledgePackageCheckPanel";

const clock = 1_700_000_000_000;
const reportId = "11111111-1111-4111-8111-111111111111";
const sourcePath = "/tmp/{sourcePath}-来源路径：{sha256}.json";
const packageSha = "a".repeat(64);
const manifestSha = "b".repeat(64);

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => { resolve = resolvePromise; reject = rejectPromise; });
  return { promise, resolve, reject };
}

function report(): KnowledgePackageCheckReport {
  return {
    reportId,
    sourcePath,
    format: "repopress-knowledge-saved-files",
    schemaVersion: 1,
    sourceManifestSchemaVersion: 4,
    scope: "selectedKnowledgePackage",
    itemCount: 1_234,
    revisionCount: 2_345,
    bodyFileCount: 600,
    archiveFileCount: 400,
    resourceByteSize: 1_234_567,
    byteSize: 2_345_678,
    sha256: packageSha,
    manifestSha256: manifestSha,
    exclusions: [...KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS],
    limits: KNOWLEDGE_PACKAGE_CHECK_LIMITS,
    structureVerified: true,
    contentVerified: true,
    allSavedReferencesIncluded: true,
    sourceManifestHashVerified: false,
    consistentSnapshot: false,
    includesCredentialStores: false,
    includesCompletedOperations: false,
    externalReferencesIncluded: false,
    filesystemWrites: false,
    currentLibraryChanged: false,
    restoreReady: false,
    checkedAtEpochMs: clock,
    expiresAtEpochMs: clock + 300_000,
  };
}

function preflight(): KnowledgePackageMemoryPreflight {
  return {
    reportId,
    sourcePath,
    byteSize: 2_345_678,
    sha256: packageSha,
    manifestSha256: manifestSha,
    stagedFileCount: 1_000,
    stagedByteSize: 1_234_567,
    staging: "ephemeralMemory",
    sourceRevalidated: true,
    filesystemWrites: false,
    currentLibraryChanged: false,
    restoreReady: false,
  };
}

type GatewayMock = { [K in keyof KnowledgePackageCheckGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;

async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function click(pattern: RegExp) { const target = button(pattern); expect(target).toBeDefined(); await act(async () => target!.click()); await settle(); }

describe("KnowledgePackageCheckPanel localization lifecycle", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(clock);
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.useRealTimers();
  });

  it("keeps one pending source selection across zh-en-zh", async () => {
    const pending = deferred<string | null>();
    const gateway = {
      selectKnowledgePackageSource: vi.fn(() => pending.promise),
      inspectKnowledgePackage: vi.fn(),
      preflightKnowledgePackage: vi.fn(),
      discardKnowledgePackageCheck: vi.fn(async () => undefined),
    } as GatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgePackageCheckPanel, { gateway: gateway as unknown as KnowledgePackageCheckGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/选择资料 JSON 包/);
    await render("en-US");
    expect(host.textContent).toContain("Selecting knowledge JSON package");
    await render("zh-CN");
    expect(host.textContent).toContain("正在选择资料 JSON 包");
    expect(gateway.selectKnowledgePackageSource).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageCheck).not.toHaveBeenCalled();

    pending.resolve(sourcePath);
    await settle();
    expect(host.textContent).toContain(`来源路径：${sourcePath}`);
    expect(gateway.inspectKnowledgePackage).not.toHaveBeenCalled();
  });

  it("relocalizes a pending inspection and report without changing bindings or extending TTL", async () => {
    const pending = deferred<KnowledgePackageCheckReport>();
    const gateway = {
      selectKnowledgePackageSource: vi.fn(async () => sourcePath),
      inspectKnowledgePackage: vi.fn(() => pending.promise),
      preflightKnowledgePackage: vi.fn(),
      discardKnowledgePackageCheck: vi.fn(async () => undefined),
    } as GatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgePackageCheckPanel, { gateway: gateway as unknown as KnowledgePackageCheckGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/选择资料 JSON 包/);
    await click(/明确检查资料 JSON 包/);
    expect(gateway.inspectKnowledgePackage).toHaveBeenCalledWith(sourcePath);
    await render("en-US");
    expect(host.textContent).toContain("Checking knowledge JSON package");
    expect(host.textContent).toContain(`Source path: ${sourcePath}`);
    expect(host.textContent).toContain("{sourcePath}");
    expect(host.textContent).toContain("{sha256}");
    await render("zh-CN");
    expect(host.textContent).toContain("正在检查资料 JSON 包");
    expect(gateway.inspectKnowledgePackage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageCheck).not.toHaveBeenCalled();

    pending.resolve(report());
    await settle();
    await render("en-US");
    expect(host.textContent).toContain("Knowledge items: 1,234; historical revisions: 2,345");
    expect(host.textContent).toContain(new Date(clock).toLocaleString("en-US"));
    expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("en-US"));
    expect(host.textContent).toContain(`Package SHA-256: ${packageSha}`);
    expect(host.textContent).toContain(`Package manifest SHA-256: ${manifestSha}`);
    expect(host.textContent).toContain("Credential stores, Other workspace sources");
    await render("zh-CN");
    expect(host.textContent).toContain("资料项：1,234；历史修订：2,345");
    expect(gateway.inspectKnowledgePackage).toHaveBeenCalledTimes(1);

    await act(async () => vi.advanceTimersByTime(299_999));
    expect(host.textContent).toContain(`包 SHA-256：${packageSha}`);
    await render("en-US");
    await act(async () => vi.advanceTimersByTime(1));
    expect(gateway.discardKnowledgePackageCheck).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageCheck).toHaveBeenCalledWith(reportId);
    expect(host.textContent).toContain("The check report expired");
  });

  it("keeps one consumed preflight plan and exact report binding across zh-en-zh", async () => {
    const pending = deferred<KnowledgePackageMemoryPreflight>();
    const gateway = {
      selectKnowledgePackageSource: vi.fn(async () => sourcePath),
      inspectKnowledgePackage: vi.fn(async () => report()),
      preflightKnowledgePackage: vi.fn(() => pending.promise),
      discardKnowledgePackageCheck: vi.fn(async () => undefined),
    } as GatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgePackageCheckPanel, { gateway: gateway as unknown as KnowledgePackageCheckGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/选择资料 JSON 包/);
    await click(/明确检查资料 JSON 包/);
    await click(/明确执行一次性内存预检/);
    expect(gateway.preflightKnowledgePackage).toHaveBeenCalledWith(reportId);
    await render("en-US");
    expect(host.textContent).toContain("Running one-time in-memory preflight");
    await render("zh-CN");
    expect(host.textContent).toContain("正在执行一次性内存预检");
    expect(gateway.preflightKnowledgePackage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageCheck).not.toHaveBeenCalled();

    pending.resolve(preflight());
    await settle();
    await render("en-US");
    expect(host.textContent).toContain("One-time in-memory preflight complete");
    expect(host.textContent).toContain(`Source path: ${sourcePath}`);
    expect(host.textContent).toContain(`Package SHA-256: ${packageSha}`);
    expect(host.textContent).toContain(`Package manifest SHA-256: ${manifestSha}`);
    expect(host.textContent).toContain("Package size: 2,345,678 bytes; staged files: 1,000; staged bytes: 1,234,567");
    expect(gateway.preflightKnowledgePackage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageCheck).not.toHaveBeenCalled();
  });

  it("renders a delayed controlled inspection error in the current locale without retrying", async () => {
    const pending = deferred<KnowledgePackageCheckReport>();
    const gateway = {
      selectKnowledgePackageSource: vi.fn(async () => sourcePath),
      inspectKnowledgePackage: vi.fn(() => pending.promise),
      preflightKnowledgePackage: vi.fn(),
      discardKnowledgePackageCheck: vi.fn(async () => undefined),
    } as GatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgePackageCheckPanel, { gateway: gateway as unknown as KnowledgePackageCheckGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/选择资料 JSON 包/);
    await click(/明确检查资料 JSON 包/);
    await render("en-US");
    pending.reject(new Error("fixture-secret transport failure"));
    await settle();
    expect(host.textContent).toContain("The knowledge JSON package check failed");
    expect(host.textContent).not.toContain("fixture-secret");
    await render("zh-CN");
    expect(host.textContent).toContain("资料 JSON 包检查失败");
    expect(gateway.inspectKnowledgePackage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageCheck).not.toHaveBeenCalled();
  });
});
