import { useEffect, useRef, type RefObject } from "react";

const focusableSelector = "button, input, select, textarea, a[href], [tabindex], [contenteditable='true']";
const inertOwners = new WeakMap<HTMLElement, { count: number }>();
const activeDrawers = new Set<HTMLElement>();

function isInert(element: HTMLElement): boolean {
  return element.inert || element.hasAttribute("inert");
}

function isHiddenFromAssistiveTechnology(element: HTMLElement): boolean {
  for (let current: HTMLElement | null = element; current; current = current.parentElement) {
    if (current.hidden || current.getAttribute("aria-hidden") === "true" || isInert(current)) return true;
    const style = window.getComputedStyle(current);
    if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return true;
  }
  return false;
}

function isEnabledFocusableElement(element: HTMLElement): boolean {
  if (!element.isConnected || !element.matches(focusableSelector)) return false;
  if (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true" || element.tabIndex < 0) return false;
  return !isHiddenFromAssistiveTechnology(element);
}

function isSafeRestoreTarget(element: HTMLElement | null): element is HTMLElement {
  if (!element || !element.isConnected || element === document.body || element === document.documentElement) return false;
  if (element.matches(":disabled") || element.getAttribute("aria-disabled") === "true") return false;
  return !isHiddenFromAssistiveTechnology(element);
}

function acquireInert(element: HTMLElement) {
  const existing = inertOwners.get(element);
  if (existing) {
    existing.count += 1;
    return;
  }
  // An already-inert sibling is controlled by somebody else (for example a
  // closed sibling drawer). Do not claim it and later restore stale state.
  if (isInert(element)) return;
  inertOwners.set(element, { count: 1 });
  element.inert = true;
}

function releaseInert(element: HTMLElement) {
  const existing = inertOwners.get(element);
  if (!existing) return;
  existing.count -= 1;
  if (existing.count > 0) return;
  element.inert = false;
  inertOwners.delete(element);
}

/** Returns only controls that are currently reachable by keyboard and assistive technology. */
export function getDrawerFocusableElements(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(focusableSelector)).filter(isEnabledFocusableElement);
}

function focusFallback() {
  // The body remains connected across drawer transitions and is preferable to a hidden drawer.
  const body = document.body;
  if (!body) return;
  const hadTabIndex = body.hasAttribute("tabindex");
  const tabIndex = body.getAttribute("tabindex");
  if (!hadTabIndex) body.tabIndex = -1;
  body.focus();
  if (!hadTabIndex) body.removeAttribute("tabindex");
  else if (tabIndex !== null) body.setAttribute("tabindex", tabIndex);
}

export function useDrawerFocus(open: boolean, root: RefObject<HTMLElement | null>, onClose: () => void) {
  const onCloseRef = useRef(onClose);
  useEffect(() => { onCloseRef.current = onClose; }, [onClose]);

  useEffect(() => {
    if (!open) return;
    const node = root.current;
    if (!node) return;

    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const siblings = node.parentElement
      ? Array.from(node.parentElement.children).filter((element): element is HTMLElement => element instanceof HTMLElement && element !== node)
      : [];
    siblings.forEach(acquireInert);
    activeDrawers.add(node);

    queueMicrotask(() => {
      if (!activeDrawers.has(node)) return;
      const first = getDrawerFocusableElements(node)[0];
      if (first) first.focus();
      else if (!isHiddenFromAssistiveTechnology(node)) node.focus();
    });

    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab") return;

      const items = getDrawerFocusableElements(node);
      if (!items.length) {
        event.preventDefault();
        if (!isHiddenFromAssistiveTechnology(node)) node.focus();
        return;
      }

      const active = document.activeElement;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && (active === first || !items.includes(active as HTMLElement))) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (active === last || !items.includes(active as HTMLElement))) {
        event.preventDefault();
        first.focus();
      }
    };

    node.addEventListener("keydown", handler);
    return () => {
      node.removeEventListener("keydown", handler);
      activeDrawers.delete(node);
      siblings.forEach(releaseInert);
      queueMicrotask(() => {
        if (activeDrawers.size > 0) return;
        if (isSafeRestoreTarget(previous)) previous.focus();
        else focusFallback();
      });
    };
  }, [open, root]);
}
