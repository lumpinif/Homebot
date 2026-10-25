// Appearance: follow the system, or the viewer's own choice. The choice is a per-viewer
// convenience kept in localStorage; the page works the same without it.
export type ThemePref = "system" | "light" | "dark";
const KEY = "homebot.theme";
const media = window.matchMedia("(prefers-color-scheme: dark)");

export function readTheme(): ThemePref {
  try {
    const v = localStorage.getItem(KEY);
    return v === "light" || v === "dark" ? v : "system";
  } catch {
    return "system";
  }
}

function apply(pref: ThemePref): void {
  const dark = pref === "dark" || (pref === "system" && media.matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

export function setTheme(pref: ThemePref): void {
  try {
    if (pref === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, pref);
  } catch {
    // Storage refused (private window): the choice lasts for this page only.
  }
  current = pref;
  apply(pref);
}

let current = readTheme();
apply(current);
media.addEventListener("change", () => apply(current));
