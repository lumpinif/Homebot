// macOS-style controls: colour-only hover, a sliding highlight for segmented controls. Nothing
// changes size or weight on hover.
import { motion } from "motion/react";
import { useReducedMotion } from "@/lib/reduced-motion";
import { useId, useRef, type KeyboardEvent, type ReactNode } from "react";
import { cn } from "@/lib/utils";

export const spring = { type: "spring", stiffness: 520, damping: 40, mass: 0.7 } as const;

/** The segmented look, shared by the appearance switch and the page tabs: a track, items, and
 *  a thumb that slides to the selected item. */
export const seg = {
  track: "inline-flex rounded-[10px] bg-fill-2 p-[2px]",
  item: "relative flex h-[26px] flex-1 items-center justify-center rounded-[8px] px-3.5 text-[13px] whitespace-nowrap transition-colors",
  on: "text-label",
  off: "text-label-2 hover:text-label",
  thumb: "absolute inset-0 rounded-[8px] bg-control shadow-[0_1px_2px_rgb(0_0_0/0.12),0_0_0_0.5px_rgb(0_0_0/0.04)]",
};

export function Segmented<T extends string>({
  value,
  options,
  onChange,
  label,
  className,
}: {
  value: T;
  options: { value: T; label: ReactNode; name?: string }[];
  onChange: (v: T) => void;
  label: string;
  className?: string;
}) {
  const id = useId();
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  // One tab stop; arrow keys move and select, wrapping, as native radios do.
  const onKey = (e: KeyboardEvent) => {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    if (!step) return;
    e.preventDefault();
    const i = (options.findIndex((o) => o.value === value) + step + options.length) % options.length;
    onChange(options[i].value);
    ref.current?.querySelectorAll<HTMLButtonElement>("[role=radio]")[i]?.focus();
  };
  return (
    <div ref={ref} role="radiogroup" aria-label={label} onKeyDown={onKey} className={cn(seg.track, className)}>
      {options.map((o) => {
        const on = o.value === value;
        return (
          <button
            key={o.value}
            role="radio"
            aria-checked={on}
            tabIndex={on ? 0 : -1}
            aria-label={o.name}
            title={o.name}
            onClick={() => onChange(o.value)}
            className={cn(seg.item, on ? seg.on : seg.off)}
          >
            {on && (
              <motion.span
                layoutId={`seg-${id}`}
                transition={reduce ? { duration: 0 } : spring}
                className={seg.thumb}
              />
            )}
            <span className="relative">{o.label}</span>
          </button>
        );
      })}
    </div>
  );
}

type ButtonKind = "primary" | "secondary" | "plain";
export function Button({
  kind = "secondary",
  children,
  className,
  ...rest
}: { kind?: ButtonKind; children: ReactNode; className?: string } & React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      {...rest}
      className={cn(
        "inline-flex h-8 items-center justify-center gap-1.5 rounded-full px-4 text-[13px] whitespace-nowrap transition-colors disabled:opacity-40",
        kind === "primary" && "bg-accent-fill text-white hover:bg-[color-mix(in_srgb,var(--accent-fill),black_10%)]",
        kind === "secondary" && "bg-fill-2 text-label hover:bg-[color-mix(in_srgb,var(--fill-2),var(--label)_6%)]",
        kind === "plain" && "text-accent hover:text-[color-mix(in_srgb,var(--accent),black_18%)]",
        className,
      )}
    >
      {children}
    </button>
  );
}

export function Check({ className }: { className?: string }) {
  return (
    <span className={cn("grid size-[22px] shrink-0 place-items-center rounded-full bg-green text-white", className)}>
      <svg viewBox="0 0 16 16" className="size-[12px]" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
        <path d="M3.5 8.5 6.5 11.5 12.5 4.5" />
      </svg>
    </span>
  );
}
