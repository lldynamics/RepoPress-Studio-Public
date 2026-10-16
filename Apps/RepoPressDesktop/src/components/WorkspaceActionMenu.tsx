import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

/** Secondary actions stay mounted so closing a menu does not discard an operation. */
export function WorkspaceActionMenu({ label, children, className = "" }: { label: string; children: ReactNode; className?: string }) {
  const menu = useRef<HTMLDetailsElement>(null);
  const [popupStyle, setPopupStyle] = useState<CSSProperties>({});
  function fitPopup() {
    const details = menu.current;
    const summary = details?.querySelector("summary");
    if (!details?.open || !summary) return;
    const bounds = details.closest(".resizable-workspace, .studio-content")?.getBoundingClientRect();
    const trigger = summary.getBoundingClientRect();
    const below = (bounds?.bottom ?? window.innerHeight) - trigger.bottom - 12;
    const above = trigger.top - (bounds?.top ?? 0) - 12;
    const opensAbove = below < 120 && above > below;
    setPopupStyle({
      maxHeight: `${Math.max(64, Math.min(480, opensAbove ? above : below))}px`,
      top: opensAbove ? "auto" : "calc(100% + 5px)",
      bottom: opensAbove ? "calc(100% + 5px)" : "auto",
    });
  }
  useEffect(() => {
    function closeOutside(event: PointerEvent) {
      if (event.target instanceof Node && !menu.current?.contains(event.target)) menu.current?.removeAttribute("open");
    }
    document.addEventListener("pointerdown", closeOutside);
    return () => document.removeEventListener("pointerdown", closeOutside);
  }, []);
  return <details ref={menu} className={`workspace-action-menu ${className}`.trim()} onToggle={fitPopup} onKeyDown={(event) => {
    if (event.key !== "Escape" || !event.currentTarget.open) return;
    event.preventDefault(); event.stopPropagation();
    event.currentTarget.open = false;
    event.currentTarget.querySelector("summary")?.focus();
  }}>
    <summary>{label}</summary>
    <div className="workspace-action-menu-content" style={popupStyle} onClick={(event) => {
      const button = (event.target as Element).closest("button");
      if (button && !button.disabled) menu.current?.removeAttribute("open");
    }}>{children}</div>
  </details>;
}
