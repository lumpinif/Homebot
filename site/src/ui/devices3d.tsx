// The flow's devices in 3D. three.js and the models load on demand; until a device is ready its
// place stays empty and it fades in, so nothing low-quality flashes. The flat drawing passed as
// fallback shows only where WebGL or the download fails.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { cn } from "@/lib/utils";
import { useReducedMotion } from "@/lib/reduced-motion";
import type { DeviceHandle, DeviceKind } from "./devices3d-scene";

const isDark = () => document.documentElement.classList.contains("dark");

let scene: Promise<typeof import("./devices3d-scene")> | null = null;
/** Starts fetching three.js and the models; safe to call often. */
export const preloadDevices = () => (scene ??= import("./devices3d-scene"));

export function Device3D({ kind, lit, fallback, className }: { kind: DeviceKind; lit: boolean; fallback: ReactNode; className?: string }) {
  const host = useRef<HTMLDivElement>(null);
  const handle = useRef<DeviceHandle | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "failed">("loading");
  const reduce = useReducedMotion();
  const latest = useRef({ lit, reduce });
  latest.current = { lit, reduce };

  useEffect(() => {
    let dead = false;
    preloadDevices()
      .then(({ mountDevice }) => {
        if (dead || !host.current) return;
        const h = mountDevice(host.current, kind, { dark: isDark(), reduce: latest.current.reduce });
        if (!h) return setState("failed");
        h.setLit(latest.current.lit);
        handle.current = h;
        setState("ready");
      })
      .catch(() => {
        scene = null;
        if (!dead) setState("failed");
      });
    // The theme menu toggles html.dark; follow it.
    const mo = new MutationObserver(() => handle.current?.setDark(isDark()));
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    return () => {
      dead = true;
      mo.disconnect();
      handle.current?.dispose();
      handle.current = null;
      setState("loading");
    };
  }, [kind]);

  useEffect(() => handle.current?.setLit(lit), [lit, state]);
  useEffect(() => handle.current?.setReduce(reduce), [reduce, state]);

  return (
    <div className={cn("relative", className)}>
      {state === "failed" && <div className="absolute inset-0 grid place-items-end justify-center">{fallback}</div>}
      <div ref={host} className={cn("absolute inset-0 transition-opacity duration-500", state === "ready" ? "opacity-100" : "opacity-0")} />
    </div>
  );
}
