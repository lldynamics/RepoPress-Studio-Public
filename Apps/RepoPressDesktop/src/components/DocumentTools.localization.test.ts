import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { open } from "@tauri-apps/plugin-dialog";
import type { DocumentCapabilities, PdfOcrExtraction, PdfSelection, SemanticSearchSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { DocumentAnalysisPanel, type DocumentAnalysisGateway } from "./DocumentAnalysisPanel";
import { SemanticSearchPanel, type SemanticSearchGateway } from "./SemanticSearchPanel";

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

describe("document tool localization", () => {
  let host: HTMLDivElement;
  let root: Root;
  let gateway: SemanticSearchGateway;
  const index = { ready: true, sessionOnly: true, modelId: "model-id", encodingVersion: 1, indexedFiles: 2, indexedChunks: 3, indexedBytes: 2048, reusedChunks: 1, summary: "backend summary" };

  function render(locale: "zh-CN" | "en-US") {
    act(() => root.render(createElement(I18nProvider, { locale, children: createElement(SemanticSearchPanel, {
      sessionId: "session", enabled: true, active: true, gateway, onOpenPath: vi.fn(),
    }) })));
  }

  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = { semanticIndexStatus: vi.fn(async () => index), rebuildSemanticIndex: vi.fn(async () => index), semanticSearch: vi.fn(async () => ({ query: "q", modelId: "model-id", encodingVersion: 1, truncated: false, results: [{ chunkId: "1", path: "标题.md", line: 2, endLine: 2, heading: "原始标题", score: 0.5, lexicalScore: 0.2, semanticScore: 0.3, snippet: "原始片段", reason: "原始原因", modelId: "model-id", encodingVersion: 1 }] })) };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); });

  it("changes labels in place while preserving the pending index request", async () => {
    let resolve!: (value: typeof index) => void;
    gateway.semanticIndexStatus = vi.fn((_sessionId: string) => new Promise<typeof index>(done => { resolve = done; }));
    render("zh-CN"); render("en-US");
    expect(gateway.semanticIndexStatus).toHaveBeenCalledTimes(1);
    await act(async () => resolve(index));
    expect(host.textContent).toContain("Offline semantic search");
    expect(host.textContent).toContain("backend summary");
  });

  it("localizes known document warnings and result details while keeping unknown backend text literal", async () => {
    const capabilities: DocumentCapabilities = { pdfTextReady: true, sandbox: { available: true, path: null, reason: null }, pdftotext: { available: true, path: null, reason: null }, ocr: { enabled: true, ready: true, tesseract: { available: true, path: null, reason: null }, pdftoppm: { available: true, path: null, reason: null }, englishData: { available: true, path: null, reason: null }, chineseSimplifiedData: { available: true, path: null, reason: null }, pdfInfo: { available: true, path: null, reason: null }, warning: "backend OCR warning" }, warnings: ["ocr_page_empty", "catalog-looking backend warning"] };
    const selection: PdfSelection = { token: "token", fileName: "sample.pdf", byteSize: 10, expiresAtEpochSeconds: Math.floor(Date.now() / 1000) + 300, warnings: ["pdf_text_layer_empty", "标题"] };
    const gateway: DocumentAnalysisGateway = { documentCapabilities: vi.fn(async () => capabilities), selectPdf: vi.fn(async () => selection), extractPdfText: vi.fn(async () => ({ text: "PDF text", byteSize: 8, warnings: ["pdf_text_sanitized"] })), extractPdfOcr: vi.fn(async () => ({ text: "OCR text", byteSize: 8, pageCount: 2, language: "chi_sim" as const, warnings: ["ocr_text_sanitized"] })), importKnowledgeText: vi.fn(async () => ({ item: {} as never, deduplicated: false, summary: "" })) };
    vi.mocked(open).mockResolvedValueOnce("/tmp/sample.pdf");
    act(() => root.render(createElement(I18nProvider, { locale: "en-US", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    expect(host.textContent).toContain("At least one page had no recognized text.");
    expect(host.textContent).toContain("catalog-looking backend warning");
    await act(async () => host.querySelectorAll<HTMLButtonElement>("button")[1].click());
    expect(host.textContent).toContain("Source: Existing PDF text layer · OCR not required");
    expect(host.getAttribute("aria-label")).toBeNull();
    expect(host.querySelector(".tool-result")?.getAttribute("aria-label")).toBe("PDF text analysis result");
  });

  it("preserves the PDF/OCR selection, consent, pending requests, and import payload through locale changes", async () => {
    let resolveCapabilities!: (value: DocumentCapabilities) => void;
    let resolveSelection!: (value: PdfSelection) => void;
    let resolveOcr!: (value: PdfOcrExtraction) => void;
    let resolveImport!: (value: { item: never; deduplicated: boolean; summary: string }) => void;
    const capabilities: DocumentCapabilities = { pdfTextReady: false, sandbox: { available: true, path: null, reason: null }, pdftotext: { available: false, path: null, reason: null }, ocr: { enabled: true, ready: true, tesseract: { available: true, path: null, reason: null }, pdftoppm: { available: true, path: null, reason: null }, englishData: { available: true, path: null, reason: null }, chineseSimplifiedData: { available: true, path: null, reason: null }, pdfInfo: { available: true, path: null, reason: null }, warning: "" }, warnings: [] };
    const selection: PdfSelection = { token: "single-use-token", fileName: "原始.pdf", byteSize: 42, expiresAtEpochSeconds: Math.floor(Date.now() / 1000) + 300, warnings: [] };
    const extractResult = { text: "原始 OCR 正文 {literal}", byteSize: 22, pageCount: 2, language: "chi_sim" as const, warnings: [] };
    const importCall = vi.fn((_request: Parameters<DocumentAnalysisGateway["importKnowledgeText"]>[0]) => new Promise<typeof resolveImport extends (value: infer V) => void ? V : never>(done => { resolveImport = done; }));
    const gateway: DocumentAnalysisGateway = {
      documentCapabilities: vi.fn(() => new Promise<DocumentCapabilities>(done => { resolveCapabilities = done; })),
      selectPdf: vi.fn(() => new Promise<PdfSelection>(done => { resolveSelection = done; })),
      extractPdfText: vi.fn(async () => ({ text: "unused", byteSize: 0, warnings: [] })),
      extractPdfOcr: vi.fn(() => new Promise<PdfOcrExtraction>(done => { resolveOcr = done; })),
      importKnowledgeText: importCall,
    };
    vi.mocked(open).mockResolvedValueOnce("/tmp/original.pdf");
    act(() => root.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    expect(gateway.documentCapabilities).toHaveBeenCalledTimes(1);
    act(() => root.render(createElement(I18nProvider, { locale: "en-US", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    expect(gateway.documentCapabilities).toHaveBeenCalledTimes(1);
    await act(async () => resolveCapabilities(capabilities));
    act(() => root.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    await act(async () => resolveSelection(selection));
    expect(gateway.selectPdf).toHaveBeenCalledTimes(1);
    const ocrSelect = host.querySelector<HTMLSelectElement>("#ocr-language")!;
    await act(async () => { ocrSelect.value = "chi_sim"; ocrSelect.dispatchEvent(new Event("change", { bubbles: true })); });
    await act(async () => host.querySelectorAll<HTMLButtonElement>("button")[2].click());
    expect(gateway.extractPdfOcr).toHaveBeenCalledWith("single-use-token", "chi_sim");
    expect(host.textContent).toContain("正在本地 OCR…");
    act(() => root.render(createElement(I18nProvider, { locale: "en-US", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    expect(gateway.extractPdfOcr).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("Running local OCR…");
    expect(host.querySelector<HTMLSelectElement>("#ocr-language")?.value).toBe("chi_sim");
    await act(async () => resolveOcr(extractResult));
    expect(host.textContent).toContain(extractResult.text);
    act(() => root.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    const consent = host.querySelector<HTMLInputElement>("#pdf-knowledge-semantic")!;
    await act(async () => { consent.click(); });
    await act(async () => { const buttons = Array.from(host.querySelectorAll<HTMLButtonElement>("button")); buttons[buttons.length - 1].click(); });
    expect(importCall).toHaveBeenCalledTimes(1);
    expect(importCall.mock.calls[0][0]).toMatchObject({ sourceName: "原始.pdf", text: extractResult.text, allowsLocalSemanticIndex: true });
    expect(host.textContent).toContain("正在导入…");
    act(() => root.render(createElement(I18nProvider, { locale: "en-US", children: createElement(DocumentAnalysisPanel, { enabled: true, isDemo: false, active: true, gateway }) })));
    expect(importCall).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("Importing…");
    expect(host.querySelector<HTMLInputElement>("#pdf-knowledge-semantic")).toBe(consent);
    expect(consent.checked).toBe(true);
    expect(host.textContent).toContain(extractResult.text);
    await act(async () => resolveImport({ item: {} as never, deduplicated: false, summary: "" }));
  });

  it("preserves semantic query, pending result state, literal fields, and open payload through locale changes", async () => {
    let resolveStatus!: (value: typeof index) => void;
    let resolveSearch!: (value: Awaited<ReturnType<SemanticSearchGateway["semanticSearch"]>>) => void;
    const openPath = vi.fn();
    const searchResult = { chunkId: "raw", path: "原始.md", line: 7, endLine: 8, heading: "原始标题", score: 0.5, lexicalScore: 0.2, semanticScore: 0.3, snippet: "原始 snippet {literal}", reason: "原始 reason", modelId: "raw-model", encodingVersion: 1 };
    const semanticGateway: SemanticSearchGateway = {
      semanticIndexStatus: vi.fn(() => new Promise<typeof index>(done => { resolveStatus = done; })),
      rebuildSemanticIndex: vi.fn(async () => index),
      semanticSearch: vi.fn((_sessionId: string, _query: string) => new Promise<SemanticSearchSnapshot>(done => { resolveSearch = done; })),
    };
    act(() => root.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(SemanticSearchPanel, { sessionId: "session", enabled: true, active: true, gateway: semanticGateway, onOpenPath: openPath }) })));
    await act(async () => resolveStatus(index));
    const query = host.querySelector<HTMLInputElement>("#semantic-search-query")!;
    await act(async () => { const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!; setValue.call(query, "原始 query {literal}"); query.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: "原始 query {literal}" })); });
    await act(async () => host.querySelector<HTMLButtonElement>("form button[type=submit]")!.click());
    expect(semanticGateway.semanticSearch).toHaveBeenCalledTimes(1);
    expect(semanticGateway.semanticSearch).toHaveBeenCalledWith("session", "原始 query {literal}", 20);
    expect(host.textContent).toContain("正在处理本地索引…");
    act(() => root.render(createElement(I18nProvider, { locale: "en-US", children: createElement(SemanticSearchPanel, { sessionId: "session", enabled: true, active: true, gateway: semanticGateway, onOpenPath: openPath }) })));
    expect(semanticGateway.semanticSearch).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("Processing local index…");
    await act(async () => resolveSearch({ query: "原始 query {literal}", modelId: "raw-model", encodingVersion: 1, truncated: false, results: [searchResult] }));
    act(() => root.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(SemanticSearchPanel, { sessionId: "session", enabled: true, active: true, gateway: semanticGateway, onOpenPath: openPath }) })));
    expect(semanticGateway.semanticSearch).toHaveBeenCalledTimes(1);
    expect(host.querySelector<HTMLInputElement>("#semantic-search-query")).toBe(query);
    expect(host.querySelector<HTMLInputElement>("#semantic-search-query")?.value).toBe("原始 query {literal}");
    expect(host.textContent).toContain(searchResult.snippet);
    expect(host.textContent).toContain(searchResult.reason);
    expect(host.textContent).toContain(index.modelId);
    expect(host.textContent).toContain(searchResult.path);
    await act(async () => host.querySelector<HTMLButtonElement>(".tool-result")!.click());
    expect(openPath).toHaveBeenCalledWith(searchResult.path);
  });
});
