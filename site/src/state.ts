// The site's views and where it links to.
import { createContext, useContext } from "react";

export const REPO_URL = "https://github.com/lumpinif/Homebot";
/** "Download for Mac": the newest release zip, served by the homebot.fun Worker (cloud/), which
 *  redirects to the versioned file and counts downloads per link from `?from=`. */
export function downloadUrl(from: "home" | "install"): string {
  return `https://homebot.fun/download/latest?from=${from}`;
}

export const PAGES = ["home", "install", "privacy"] as const;
export type Page = (typeof PAGES)[number];

/** Opens a view: the shell's navigation, for links inside views. */
export const GoContext = createContext<(p: Page) => void>(() => {});
export const useGo = () => useContext(GoContext);
