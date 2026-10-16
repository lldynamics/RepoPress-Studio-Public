import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { getMarkdownDiagnostics, type MarkdownDiagnostic } from "./markdownDiagnostics";
import type { MarkdownDiagnosticsWorkerResponse } from "./markdownDiagnostics.worker";

export interface MarkdownDiagnosticsSession {
  diagnostics: MarkdownDiagnostic[];
  status: "idle" | "ready" | "pending" | "cancelled" | "unavailable" | "error" | "too-large";
  source: string;
  documentKey: string | undefined;
  truncated: boolean;
  cancel: () => void;
  retry: () => void;
}

interface PreparedTitles {
  supported: boolean;
  titles: string[] | undefined;
  key: string;
}

interface Binding {
  source: string;
  documentKey: string | undefined;
  contextKey: string;
  generation: number;
  revision: number;
}

interface StoredResult extends Binding {
  diagnostics: MarkdownDiagnostic[];
  status: "ready" | "cancelled" | "unavailable" | "error";
  truncated: boolean;
}

interface ActiveOperation extends Binding {
  stop: () => void;
}

interface RenderInput {
  source: string;
  documentKey: string | undefined;
  contextKey: string;
  enabled: boolean;
  generation: number;
}

const SMALL_DOCUMENT_LENGTH = 32 * 1024;
const MAX_DOCUMENT_LENGTH = 512 * 1024;
const MAX_KNOWN_TITLES = 20_000;
const MAX_KNOWN_TITLE_CHARACTERS = 1024 * 1024;
const MAX_DIAGNOSTICS = 500;
const DEBOUNCE_MS = 200;
const TIMEOUT_MS = 5_000;
let nextRequestId = 0;

function prepareKnownTitles(value: string[] | undefined): PreparedTitles {
  if (value === undefined) return { supported: true, titles: undefined, key: "undefined" };
  if (value.length > MAX_KNOWN_TITLES) return { supported: false, titles: undefined, key: "too-many" };
  let totalCharacters = 0;
  for (const title of value) {
    totalCharacters += title.length;
    if (totalCharacters > MAX_KNOWN_TITLE_CHARACTERS) return { supported: false, titles: undefined, key: "too-long" };
  }
  const titles = [...value];
  return { supported: true, titles, key: JSON.stringify(titles) };
}

function sameBinding(left: Binding, right: Binding): boolean {
  return left.source === right.source
    && left.documentKey === right.documentKey
    && left.contextKey === right.contextKey
    && left.generation === right.generation
    && left.revision === right.revision;
}

function validParameters(value: unknown): boolean {
  if (value === undefined) return true;
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.values(value).every((parameter) => typeof parameter === "string" || typeof parameter === "number");
}

function validTemplate(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const template = value as { source?: unknown; parameters?: unknown };
  return typeof template.source === "string" && validParameters(template.parameters);
}

function validPresentation(value: unknown): boolean {
  if (value === undefined) return true;
  if (!value || typeof value !== "object") return false;
  const presentation = value as { title?: unknown; message?: unknown };
  if (!validTemplate(presentation.title) || !validTemplate(presentation.message)) return false;
  const message = presentation.message as { labels?: unknown };
  if (message.labels === undefined) return true;
  if (!message.labels || typeof message.labels !== "object" || Array.isArray(message.labels)) return false;
  return Object.values(message.labels).every(validTemplate);
}

function validRelated(value: unknown, sourceLength: number): boolean {
  if (value === undefined) return true;
  if (!value || typeof value !== "object") return false;
  const related = value as { range?: { from?: unknown; to?: unknown }; line?: unknown };
  const from = related.range?.from;
  const to = related.range?.to;
  return Number.isInteger(from) && Number.isInteger(to)
    && (from as number) >= 0 && (to as number) >= (from as number) && (to as number) <= sourceLength
    && Number.isInteger(related.line) && (related.line as number) >= 1 && (related.line as number) <= sourceLength + 1;
}

function validDiagnostic(value: unknown, sourceLength: number): value is MarkdownDiagnostic {
  if (!value || typeof value !== "object") return false;
  const item = value as Partial<MarkdownDiagnostic>;
  const range = item.range;
  return typeof item.id === "string"
    && (item.severity === "warning" || item.severity === "error")
    && typeof item.title === "string"
    && typeof item.message === "string"
    && !!range && Number.isInteger(range.from) && Number.isInteger(range.to)
    && range.from >= 0 && range.to >= range.from && range.to <= sourceLength
    && (item.replacement === undefined || typeof item.replacement === "string")
    && (item.expectedText === undefined || typeof item.expectedText === "string")
    && validPresentation(item.presentation)
    && validRelated(item.related, sourceLength);
}

function validWorkerResponse(value: unknown, requestId: number, sourceLength: number): value is MarkdownDiagnosticsWorkerResponse {
  if (!value || typeof value !== "object") return false;
  const response = value as MarkdownDiagnosticsWorkerResponse;
  if (response.requestId !== requestId) return false;
  if (Object.prototype.hasOwnProperty.call(response, "error")) return typeof response.error === "string" && response.error.length > 0;
  return Array.isArray(response.diagnostics)
    && response.diagnostics.length <= MAX_DIAGNOSTICS
    && response.diagnostics.every((item) => validDiagnostic(item, sourceLength))
    && typeof response.truncated === "boolean";
}

/**
 * Keeps editor diagnostics bound to the exact source, document, and repository-title snapshot.
 * Callers must replace `knownArticleTitles` when its contents change; the hook snapshots by array identity.
 */
export function useMarkdownDiagnostics(
  value: string,
  documentKey: string | undefined,
  knownArticleTitles?: string[],
  enabled = true,
): MarkdownDiagnosticsSession {
  const preparedTitles = useMemo(() => prepareKnownTitles(knownArticleTitles), [knownArticleTitles]);
  const [revision, setRevision] = useState(0);
  const [stored, setStored] = useState<StoredResult | null>(null);
  const [renderInput, setRenderInput] = useState<RenderInput>(() => ({
    source: value,
    documentKey,
    contextKey: preparedTitles.key,
    enabled,
    generation: 0,
  }));
  const activeRef = useRef<ActiveOperation | null>(null);
  const inputChanged = renderInput.source !== value || renderInput.documentKey !== documentKey
    || renderInput.contextKey !== preparedTitles.key || renderInput.enabled !== enabled;
  const generation = inputChanged ? renderInput.generation + 1 : renderInput.generation;
  if (inputChanged) {
    setRenderInput({ source: value, documentKey, contextKey: preparedTitles.key, enabled, generation });
  }
  const binding: Binding = { source: value, documentKey, contextKey: preparedTitles.key, generation, revision };
  const committedInputRef = useRef({ source: value, documentKey, contextKey: preparedTitles.key, enabled, generation, revision });
  useLayoutEffect(() => {
    committedInputRef.current = { source: value, documentKey, contextKey: preparedTitles.key, enabled, generation, revision };
  }, [documentKey, enabled, generation, preparedTitles.key, revision, value]);

  const smallResult = useMemo(() => {
    if (!enabled || !preparedTitles.supported || value.length > SMALL_DOCUMENT_LENGTH) return null;
    const diagnostics = getMarkdownDiagnostics(value, {
      knownArticleTitles: preparedTitles.titles,
      maxIssues: MAX_DIAGNOSTICS + 1,
    });
    return { diagnostics: diagnostics.slice(0, MAX_DIAGNOSTICS), truncated: diagnostics.length > MAX_DIAGNOSTICS };
  }, [enabled, preparedTitles, value]);

  useEffect(() => {
    if (!enabled || !preparedTitles.supported || value.length <= SMALL_DOCUMENT_LENGTH || value.length > MAX_DOCUMENT_LENGTH) return;
    const effectBinding = binding;
    let active = true;
    let worker: Worker | null = null;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const finish = () => {
      if (!active) return false;
      active = false;
      clearTimeout(debounce);
      if (timeout !== undefined) clearTimeout(timeout);
      if (worker) {
        worker.onmessage = null;
        worker.onerror = null;
        worker.onmessageerror = null;
        worker.terminate();
      }
      if (activeRef.current && sameBinding(activeRef.current, effectBinding)) activeRef.current = null;
      return true;
    };
    const storeFailure = (status: StoredResult["status"]) => {
      const current = committedInputRef.current;
      if (current.generation !== effectBinding.generation || current.revision !== effectBinding.revision) { finish(); return; }
      if (!finish()) return;
      setStored({ ...effectBinding, diagnostics: [], status, truncated: false });
    };
    const debounce = setTimeout(() => {
      if (!active) return;
      if (typeof Worker === "undefined") { storeFailure("unavailable"); return; }
      try {
        worker = new Worker(new URL("./markdownDiagnostics.worker.ts", import.meta.url), { type: "module" });
      } catch {
        storeFailure("unavailable");
        return;
      }
      const requestId = ++nextRequestId;
      worker.onmessage = (event: MessageEvent<unknown>) => {
        const response = event.data;
        if (!response || typeof response !== "object" || (response as { requestId?: unknown }).requestId !== requestId) return;
        if (!validWorkerResponse(response, requestId, value.length) || response.error !== undefined) { storeFailure("error"); return; }
        const current = committedInputRef.current;
        if (current.generation !== effectBinding.generation || current.revision !== effectBinding.revision) { finish(); return; }
        if (!finish()) return;
        setStored({
          ...effectBinding,
          diagnostics: response.diagnostics ?? [],
          status: "ready",
          truncated: response.truncated ?? false,
        });
      };
      worker.onerror = () => storeFailure("error");
      worker.onmessageerror = () => storeFailure("error");
      timeout = setTimeout(() => storeFailure("error"), TIMEOUT_MS);
      try {
        worker.postMessage({ requestId, source: value, knownArticleTitles: preparedTitles.titles });
      } catch {
        storeFailure("error");
      }
    }, DEBOUNCE_MS);
    activeRef.current = { ...effectBinding, stop: finish };
    return () => { finish(); };
  }, [documentKey, enabled, generation, preparedTitles, revision, value]);

  const cancel = useCallback(() => {
    const current = committedInputRef.current;
    if (!current.enabled || value.length <= SMALL_DOCUMENT_LENGTH || value.length > MAX_DOCUMENT_LENGTH
      || !preparedTitles.supported || current.generation !== binding.generation || current.revision !== binding.revision) return;
    const cancelBinding = binding;
    if (activeRef.current && sameBinding(activeRef.current, cancelBinding)) activeRef.current.stop();
    setStored({ ...cancelBinding, diagnostics: [], status: "cancelled", truncated: false });
  }, [binding, documentKey, preparedTitles, value]);

  const retry = useCallback(() => {
    const current = committedInputRef.current;
    if (!current.enabled || value.length <= SMALL_DOCUMENT_LENGTH || value.length > MAX_DOCUMENT_LENGTH
      || !preparedTitles.supported || current.generation !== binding.generation || current.revision !== binding.revision) return;
    if (activeRef.current && sameBinding(activeRef.current, binding)) activeRef.current.stop();
    setRevision((currentRevision) => currentRevision === binding.revision ? currentRevision + 1 : currentRevision);
  }, [binding, documentKey, preparedTitles, value]);

  if (!enabled) return { diagnostics: [], status: "idle", source: value, documentKey, truncated: false, cancel, retry };
  if (!preparedTitles.supported || value.length > MAX_DOCUMENT_LENGTH) {
    return { diagnostics: [], status: "too-large", source: value, documentKey, truncated: false, cancel, retry };
  }
  if (smallResult) return { ...smallResult, status: "ready", source: value, documentKey, cancel, retry };
  if (stored && sameBinding(stored, binding)) {
    return { diagnostics: stored.diagnostics, status: stored.status, source: value, documentKey, truncated: stored.truncated, cancel, retry };
  }
  return { diagnostics: [], status: "pending", source: value, documentKey, truncated: false, cancel, retry };
}
