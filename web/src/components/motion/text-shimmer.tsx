import { cn } from "@/lib/utils";
import type { ElementType, ReactNode } from "react";
import {
  TEXT_SHIMMER_CLASS_NAME,
  textShimmerStyle,
} from "@/lib/text-shimmer";

// Homebot: the keyframes are in index.css instead of a <style> element here, which the
// setup page's CSP would refuse (style-src 'self').

export interface TextShimmerProps {
  children: ReactNode;
  as?: ElementType;
  duration?: number;
  className?: string;
}

export function TextShimmer({ children, as: Comp = "span", duration = 2.5, className }: TextShimmerProps) {
  return (
    <Comp
      style={textShimmerStyle(duration)}
      className={cn(
        "inline-block",
        TEXT_SHIMMER_CLASS_NAME,
        className,
      )}
    >
      {children}
    </Comp>
  );
}
