// motion/react's useReducedMotion reads the setting once; this one follows changes made while
// the page is open, so autoplay stops as soon as Reduce Motion is turned on.
import { useSyncExternalStore } from "react";

const query = "(prefers-reduced-motion: reduce)";
const subscribe = (cb: () => void) => {
  const mq = matchMedia(query);
  mq.addEventListener("change", cb);
  return () => mq.removeEventListener("change", cb);
};

export function useReducedMotion(): boolean {
  return useSyncExternalStore(subscribe, () => matchMedia(query).matches);
}
