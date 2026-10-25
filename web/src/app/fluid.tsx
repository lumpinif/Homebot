// Fluid-hover controls: one highlight glides to the item nearest the cursor, and the selected
// item's pill slides between options (Fluid Functionalism's motion system, MIT; see
// components/fluid/). Used wherever the page switches between options.
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AnimatePresence, motion } from "motion/react";
import { Check, ChevronDown } from "lucide-react";
import { useFluidHover } from "@/components/fluid/use-fluid-hover";
import { FluidHoverHighlight } from "@/components/fluid/fluid-hover-highlight";
import { spring } from "@/components/fluid/springs";
import { cn } from "@/lib/utils";

export interface FluidOption<V extends string> {
  value: V;
  label: ReactNode;
  /** Accessible name when the label is not plain text. */
  name?: string;
  icon?: ReactNode;
}

/** A segmented control: Apple's white pill on a grey track, with fluid hover. */
export function Segmented<V extends string>({
  value,
  options,
  onChange,
  label,
  className,
}: {
  value: V;
  options: FluidOption<V>[];
  onChange: (v: V) => void;
  label: string;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const hover = useFluidHover(ref, { axis: "x" });
  const pill = useId();
  // Arrows move the selection and the focus together (the selected tab is the one in the
  // tab order).
  const pick = (i: number) => {
    const n = (i + options.length) % options.length;
    const next = options[n];
    if (!next) return;
    onChange(next.value);
    ref.current?.querySelectorAll<HTMLElement>('[role="tab"]')[n]?.focus();
  };
  return (
    <div
      ref={ref}
      role="tablist"
      aria-label={label}
      {...hover.handlers}
      className={cn("relative flex items-center gap-0.5 rounded-full bg-muted p-[3px]", className)}
    >
      <FluidHoverHighlight hover={hover} className="rounded-full" />
      {options.map((o, i) => {
        const selected = o.value === value;
        return (
          <button
            key={o.value}
            ref={(el) => hover.registerItem(i, el)}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-label={o.name}
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(o.value)}
            onKeyDown={(e) => {
              if (e.key === "ArrowRight") pick(i + 1);
              if (e.key === "ArrowLeft") pick(i - 1);
            }}
            className={cn(
              "relative flex h-7 items-center gap-1.5 rounded-full px-3 text-[13px] font-medium outline-none transition-colors duration-150 focus-visible:ring-2 focus-visible:ring-ring",
              selected ? "text-foreground" : "text-muted-foreground hover:text-foreground",
            )}
          >
            {selected ? (
              <motion.span
                layoutId={pill}
                transition={spring.moderate}
                className="absolute inset-0 rounded-full bg-pill shadow-[0_1px_3px_rgba(0,0,0,0.12),0_1px_1px_rgba(0,0,0,0.04)]"
              />
            ) : null}
            <span className="relative flex items-center gap-1.5">
              {o.icon}
              {o.label}
            </span>
          </button>
        );
      })}
    </div>
  );
}

/** A row of suggestion chips; one highlight glides between them. */
export function Chips({ items, onPick, label }: { items: string[]; onPick: (v: string) => void; label: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const hover = useFluidHover(ref, { axis: "xy" });
  return (
    <div className="flex flex-wrap items-center gap-1.5 px-1">
      <span className="mr-0.5 text-[13px] text-muted-foreground">{label}</span>
      <div ref={ref} {...hover.handlers} className="relative flex flex-wrap items-center gap-1.5">
        <FluidHoverHighlight hover={hover} className="rounded-full" />
        {items.map((v, i) => (
          <button
            key={v}
            ref={(el) => hover.registerItem(i, el)}
            type="button"
            onClick={() => onPick(v)}
            className="relative h-7 rounded-full border border-border px-3 text-[13px] font-medium outline-none transition-colors duration-150 focus-visible:ring-2 focus-visible:ring-ring active:scale-[0.97]"
          >
            {v}
          </button>
        ))}
      </div>
    </div>
  );
}

/**
 * A dropdown list in a portal, so no card clips it. It scrolls when it is taller than the
 * room left in the window, flips above the trigger when there is more room there, and moves
 * with arrows, Home/End, typed letters, Enter and Escape.
 */
export function Picker<V extends string>({
  value,
  options,
  onChange,
  label,
  trigger,
  align = "stretch",
  labelId,
  className,
}: {
  value: V;
  options: FluidOption<V>[];
  onChange: (v: V) => void;
  label: string;
  /** Custom trigger content; defaults to the selected label. */
  trigger?: ReactNode;
  /** "stretch": a form field as wide as its column; "end": a small menu under a header button. */
  align?: "stretch" | "end";
  /** The visible label's id; screen readers then hear the label and the current value. */
  labelId?: string;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const [box, setBox] = useState<{ top: number; left: number; width: number; maxHeight: number; up: boolean } | null>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const hover = useFluidHover(listRef, { axis: "y" });
  const id = useId();
  const selectedIndex = Math.max(0, options.findIndex((o) => o.value === value));
  const selected = options[selectedIndex];

  const place = useCallback(() => {
    const t = triggerRef.current?.getBoundingClientRect();
    if (!t) return;
    const margin = 12;
    const wanted = Math.min(options.length * 40 + 10, 420);
    const below = window.innerHeight - t.bottom - margin;
    const above = t.top - margin;
    const up = below < Math.min(wanted, 200) && above > below;
    const width = align === "end" ? Math.max(180, t.width) : t.width;
    const left = align === "end" ? t.right - width : t.left;
    setBox({ top: up ? t.top - 6 : t.bottom + 6, left, width, maxHeight: Math.max(120, Math.min(wanted, up ? above : below)), up });
  }, [align, options.length]);

  useLayoutEffect(() => {
    if (!open) return;
    place();
    hover.setActiveIndex(selectedIndex);
    const onScroll = () => place();
    window.addEventListener("resize", onScroll);
    window.addEventListener("scroll", onScroll, true);
    return () => {
      window.removeEventListener("resize", onScroll);
      window.removeEventListener("scroll", onScroll, true);
    };
    // Measured once per opening; the selected row lights first.
  }, [open]);

  // The selected row starts in view.
  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      reveal(selectedIndex);
      listRef.current?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [open, selectedIndex]);

  // A press outside closes the list.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      const target = e.target instanceof Node ? e.target : null;
      if (target && (listRef.current?.contains(target) || triggerRef.current?.contains(target))) return;
      setOpen(false);
    };
    window.addEventListener("pointerdown", onDown, true);
    return () => window.removeEventListener("pointerdown", onDown, true);
  }, [open]);

  /** Scroll the list (only the list, never the page) so row `i` is in view. */
  function reveal(i: number) {
    const list = listRef.current;
    const row = list?.querySelector<HTMLElement>(`[data-index="${i}"]`);
    if (!list || !row) return;
    if (row.offsetTop < list.scrollTop) list.scrollTop = row.offsetTop - 4;
    else if (row.offsetTop + row.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = row.offsetTop + row.offsetHeight - list.clientHeight + 4;
  }
  const close = (focusTrigger = true) => {
    setOpen(false);
    if (focusTrigger) triggerRef.current?.focus({ preventScroll: true });
  };
  const choose = (i: number) => {
    const o = options[i];
    if (o && o.value !== value) onChange(o.value);
    close();
  };
  const move = (i: number) => {
    const n = Math.min(options.length - 1, Math.max(0, i));
    hover.setActiveIndex(n);
    reveal(n);
  };
  const typed = useRef({ text: "", at: 0 });
  const onListKey = (e: KeyboardEvent) => {
    const at = hover.activeIndex ?? selectedIndex;
    const typing = Date.now() - typed.current.at < 700;
    if (e.key === "ArrowDown") move(at + 1);
    else if (e.key === "ArrowUp") move(at - 1);
    else if (e.key === "Home") move(0);
    else if (e.key === "End") move(options.length - 1);
    else if (e.key === "Enter" || (e.key === " " && !typing)) choose(at);
    // Tab: focus returns to the trigger first, so the browser moves on from there.
    else if (e.key === "Escape" || e.key === "Tab") return close();
    else if (e.key.length === 1) {
      const now = Date.now();
      typed.current = { text: (typing ? typed.current.text : "") + e.key.toLowerCase(), at: now };
      const hit = options.findIndex((o) => (o.name ?? (typeof o.label === "string" ? o.label : o.value)).toLowerCase().startsWith(typed.current.text));
      if (hit >= 0) move(hit);
    } else return;
    e.preventDefault();
  };

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        id={`${id}-trigger`}
        aria-label={trigger ? `${label}: ${selected?.name ?? (typeof selected?.label === "string" ? selected.label : "")}` : undefined}
        aria-labelledby={!trigger && labelId ? `${labelId} ${id}-trigger` : undefined}
        onClick={() => setOpen((o) => !o)}
        onKeyDown={(e) => {
          if (!open && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
            e.preventDefault();
            setOpen(true);
          }
        }}
        className={cn(
          trigger
            ? "flex h-8 items-center gap-1.5 rounded-full px-2.5 text-[13px] font-medium text-muted-foreground outline-none transition-colors duration-150 hover:bg-hover hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
            : "flex h-12 w-full items-center justify-between gap-2 rounded-2xl border border-border bg-background px-4 text-left text-[15px] outline-none transition-[border-color,box-shadow] duration-150 hover:border-border-strong focus-visible:ring-2 focus-visible:ring-ring/40",
          open && !trigger && "border-border-strong",
          open && trigger && "bg-hover text-foreground",
          className,
        )}
      >
        {trigger ?? <span className="truncate">{selected?.label}</span>}
        {!trigger ? (
          <motion.span animate={{ rotate: open ? 180 : 0 }} transition={spring.moderate} className="text-muted-foreground">
            <ChevronDown className="size-4" />
          </motion.span>
        ) : null}
      </button>
      {createPortal(
        <AnimatePresence>
          {open && box ? (
            <motion.div
              key="list"
              initial={{ opacity: 0, scale: 0.97, y: box.up ? 4 : -4 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.98, transition: spring.moderate.exit }}
              transition={spring.moderate}
              style={{
                position: "fixed",
                left: box.left,
                width: box.width,
                ...(box.up ? { bottom: window.innerHeight - box.top } : { top: box.top }),
                transformOrigin: box.up ? "bottom center" : "top center",
              }}
              className="z-[90] overflow-hidden rounded-2xl border border-border bg-popover text-popover-foreground shadow-[0_12px_40px_-8px_rgba(0,0,0,0.25),0_2px_6px_rgba(0,0,0,0.06)]"
            >
              <div
                ref={listRef}
                id={id}
                role="listbox"
                aria-label={label}
                tabIndex={-1}
                aria-activedescendant={hover.activeIndex !== null ? `${id}-${hover.activeIndex}` : undefined}
                onKeyDown={onListKey}
                {...hover.handlers}
                style={{ maxHeight: box.maxHeight }}
                className="relative overflow-y-auto overscroll-contain p-1 outline-none"
              >
                <FluidHoverHighlight hover={hover} className="rounded-xl" />
                {options.map((o, i) => {
                  const isSelected = o.value === value;
                  return (
                    <div
                      key={o.value}
                      id={`${id}-${i}`}
                      ref={(el) => hover.registerItem(i, el)}
                      data-index={i}
                      role="option"
                      aria-selected={isSelected}
                      onClick={() => choose(i)}
                      className={cn(
                        "relative flex h-10 cursor-default items-center gap-2.5 rounded-xl px-3 text-[15px] select-none",
                        isSelected ? "text-foreground" : "text-foreground/80",
                      )}
                    >
                      {o.icon}
                      <span className="flex-1 truncate">{o.label}</span>
                      {isSelected ? <Check className="size-4 text-primary" strokeWidth={2.5} /> : null}
                    </div>
                  );
                })}
              </div>
            </motion.div>
          ) : null}
        </AnimatePresence>,
        document.body,
      )}
    </>
  );
}
