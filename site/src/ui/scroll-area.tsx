// Scroll Area from Fluid Functionalism by Micka Touillaud (MIT,
// https://github.com/mickadesign/fluid-functionalism, registry/radix/scroll-area.tsx), itself
// adapted from Lina by SameerJS6 (MIT, https://lina.sameer.sh). Notices: site/public/THIRD_PARTY.md (served with the site).
// Changes here: the shape and overlay tokens become the site's (a round thumb tinted with the
// label colour) and the thumb no longer widens on hover, `omit` is inlined, the touch hook sits in this file, and the viewport can be
// reached through `viewportRef` so a view change can scroll back to the top. Touch-primary
// devices get native overflow scrolling, as in the original.

import * as ScrollAreaPrimitive from "@radix-ui/react-scroll-area";
import { createContext, forwardRef, useContext, useEffect, useRef, useState, type ComponentPropsWithoutRef, type ComponentRef, type Ref } from "react";
import { cn } from "@/lib/utils";

const ScrollAreaContext = createContext<boolean>(false);
// Shown while the pointer is over the area or it is scrolling.
const ScrollbarVisibleContext = createContext<boolean>(true);
const SCROLL_LINGER_MS = 600;

/** Touch-primary devices (coarse pointer and touch points), following pointer-mode changes. */
export function useTouchPrimary() {
  const [touch, setTouch] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    const { signal } = controller;
    const mq = matchMedia("(pointer: coarse)");
    const update = () => setTouch(("ontouchstart" in window || navigator.maxTouchPoints > 0) && mq.matches);
    mq.addEventListener("change", update, { signal });
    addEventListener("pointerdown", update, { signal });
    update();
    return () => controller.abort();
  }, []);
  return touch;
}

interface ScrollAreaProps extends Omit<ComponentPropsWithoutRef<typeof ScrollAreaPrimitive.Root>, "scrollHideDelay"> {
  viewportClassName?: string;
  viewportRef?: Ref<HTMLDivElement>;
}

export const ScrollArea = forwardRef<ComponentRef<typeof ScrollAreaPrimitive.Root>, ScrollAreaProps>(
  ({ className, children, viewportClassName, viewportRef, ...props }, ref) => {
    const isTouch = useTouchPrimary();
    const [hovering, setHovering] = useState(false);
    const [scrolling, setScrolling] = useState(false);
    const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
    useEffect(
      () => () => {
        if (timer.current) clearTimeout(timer.current);
      },
      [],
    );
    const onScroll = () => {
      setScrolling(true);
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => setScrolling(false), SCROLL_LINGER_MS);
    };

    return (
      <ScrollAreaContext.Provider value={isTouch}>
        {isTouch ? (
          <div ref={ref} data-slot="scroll-area" className={cn("relative overflow-hidden", className)} {...props}>
            <div ref={viewportRef} data-slot="scroll-area-viewport" className={cn("size-full overflow-y-auto", viewportClassName)}>
              {children}
            </div>
          </div>
        ) : (
          <ScrollbarVisibleContext.Provider value={hovering || scrolling}>
            <ScrollAreaPrimitive.Root
              ref={ref}
              data-slot="scroll-area"
              // Always mounted while content overflows; showing and hiding is the opacity fade below.
              type="always"
              onPointerEnter={() => setHovering(true)}
              onPointerLeave={() => setHovering(false)}
              className={cn("relative overflow-hidden", className)}
              {...props}
            >
              <ScrollAreaPrimitive.Viewport ref={viewportRef} data-slot="scroll-area-viewport" onScroll={onScroll} className={cn("size-full", viewportClassName)}>
                {children}
              </ScrollAreaPrimitive.Viewport>
              <ScrollBar />
            </ScrollAreaPrimitive.Root>
          </ScrollbarVisibleContext.Provider>
        )}
      </ScrollAreaContext.Provider>
    );
  },
);
ScrollArea.displayName = "ScrollArea";

const ScrollBar = forwardRef<ComponentRef<typeof ScrollAreaPrimitive.ScrollAreaScrollbar>, ComponentPropsWithoutRef<typeof ScrollAreaPrimitive.ScrollAreaScrollbar>>(
  ({ className, ...props }, ref) => {
    const isTouch = useContext(ScrollAreaContext);
    const visible = useContext(ScrollbarVisibleContext);
    if (isTouch) return null;
    return (
      <ScrollAreaPrimitive.ScrollAreaScrollbar
        ref={ref}
        orientation="vertical"
        data-slot="scroll-area-scrollbar"
        data-visible={visible ? "" : undefined}
        className={cn(
          // A 10px track to aim at; the thumb is narrow and faint, and only its colour changes on hover.
          "group/scrollbar z-20 flex h-full w-2.5 touch-none select-none",
          "opacity-0 transition-opacity delay-160 duration-120 ease-out",
          "data-[visible]:opacity-100 data-[visible]:delay-0 data-[visible]:duration-160",
          "pointer-events-none data-[visible]:pointer-events-auto",
          className,
        )}
        {...props}
      >
        <ScrollAreaPrimitive.ScrollAreaThumb
          data-slot="scroll-area-thumb"
          className={cn(
            "relative mx-auto my-1 w-1.5 -translate-x-0.5 rounded-full transition-colors duration-160 ease-in-out",
            "bg-[color-mix(in_srgb,var(--label),transparent_78%)] group-hover/scrollbar:bg-[color-mix(in_srgb,var(--label),transparent_68%)] active:!bg-[color-mix(in_srgb,var(--label),transparent_58%)]",
          )}
        />
      </ScrollAreaPrimitive.ScrollAreaScrollbar>
    );
  },
);
ScrollBar.displayName = "ScrollBar";
