// Small layout pieces shared by the steps. Controls themselves come from beUI.
import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { motion } from "motion/react";
import { cn } from "@/lib/utils";

/** The app-icon tile and title that open each step. */
export function StepHeader({ icon: Icon, tint, title, children }: { icon: LucideIcon; tint: string; title: string; children?: ReactNode }) {
  return (
    <div className="flex flex-col items-center gap-4 text-center">
      <motion.div
        initial={{ scale: 0.6, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        transition={{ type: "spring", bounce: 0.45, duration: 0.6 }}
        className={cn("grid size-16 place-items-center rounded-[1.15rem] text-white shadow-lg ring-1 ring-black/5", tint)}
      >
        <Icon className="size-8" strokeWidth={2} />
      </motion.div>
      <h2 data-step-title tabIndex={-1} className="text-[28px] leading-tight font-semibold tracking-tight outline-none">
        {title}
      </h2>
      {children}
    </div>
  );
}

/** A small grey label above a control. */
export function Label({ children, htmlFor, id }: { children: ReactNode; htmlFor?: string; id?: string }) {
  return (
    <label id={id} htmlFor={htmlFor} className="px-1 text-[13px] font-medium text-muted-foreground">
      {children}
    </label>
  );
}

/** One line of quiet supporting text. */
export function Note({ children, className }: { children: ReactNode; className?: string }) {
  return <p className={cn("px-1 text-[13px] leading-snug text-muted-foreground", className)}>{children}</p>;
}

/** An inset grouped list, like iOS Settings. */
export function Group({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("divide-y divide-border overflow-hidden rounded-2xl border border-border bg-card", className)}>{children}</div>;
}

export function Row({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("flex min-h-14 items-center gap-3 px-4 py-2.5", className)}>{children}</div>;
}

