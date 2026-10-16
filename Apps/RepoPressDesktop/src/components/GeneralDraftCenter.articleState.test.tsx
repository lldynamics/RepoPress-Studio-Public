import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import type { GeneralDraft, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { GeneralDraftCenter } from "./GeneralDraftCenter";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
let root: Root | undefined;
let host: HTMLDivElement | undefined;
afterEach(async () => { await act(async () => root?.unmount()); host?.remove(); });

it("projects a loaded general draft as local only across editing and language changes without writes", async () => {
  const draft: GeneralDraft = {
    draftId: "general-1", title: "来源标题", text: "---\ndraft: false\nstatus: published\ndate: 2000-01-01\n---\n本机草稿",
    sourceRepositoryName: "旧站点", sourceRelativePath: "content/old.md", createdAtEpochSeconds: 1,
    updatedAtEpochSeconds: 1, byteSize: 100, contentSha256: "draft-sha", revision: 4,
  };
  const methods = {
    listGeneralDrafts: vi.fn(async () => ({ entries: [draft], total: 1, truncated: false })),
    getGeneralDraft: vi.fn(async () => draft), saveGeneralDraft: vi.fn(),
    planGeneralDraftTransfer: vi.fn(), executeGeneralDraftTransfer: vi.fn(),
  };
  const props = { open: true, onClose: vi.fn(), gateway: methods as unknown as RepositoryGateway,
    repository: { sessionId: "other-site", rootPath: "/other", contentRoot: "content", siteKind: "hugo", displayName: "另一个站点", isGitRepository: false, warnings: [] } as RepositorySessionSnapshot,
    document: null, currentText: "", hasUnsavedChanges: false, onTransferApplied: vi.fn() };
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  const render = async (locale: "zh-CN" | "en-US") => {
    await act(async () => root!.render(<I18nProvider locale={locale}><GeneralDraftCenter {...props} /></I18nProvider>));
  };
  await render("zh-CN");
  for (let attempt = 0; attempt < 100 && !host.querySelector(".article-state-panel"); attempt += 1) {
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
  }
  const panel = host.querySelector(".article-state-panel");
  expect(panel?.textContent).toContain("仅本地");
  expect(panel?.textContent).not.toContain("待发布");
  expect(panel?.querySelector("button")).toBeNull();
  const textarea = host.querySelector("textarea")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea, "没有 Front Matter 的新编辑");
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  });
  textarea.focus();
  await render("en-US");
  expect(host.querySelector("textarea")).toBe(textarea);
  expect(document.activeElement).toBe(textarea);
  expect(textarea.value).toBe("没有 Front Matter 的新编辑");
  expect(panel?.textContent).toContain("Local only");
  expect(panel?.textContent).not.toContain("Online status");
  expect(methods.getGeneralDraft).toHaveBeenCalledExactlyOnceWith(draft.draftId);
  expect(methods.saveGeneralDraft).not.toHaveBeenCalled();
  expect(methods.planGeneralDraftTransfer).not.toHaveBeenCalled();
  expect(methods.executeGeneralDraftTransfer).not.toHaveBeenCalled();
});
