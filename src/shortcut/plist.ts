// Minimal XML property-list writer: only the types a Shortcut uses (dict, array, string,
// integer, boolean). Not a general plist library (DESIGN D6).

const esc = (s: string): string => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
// XML 1.0 forbids most C0 control characters even when escaped.
const INVALID_XML = /[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/;

function node(v: unknown, pad: string): string {
  const inner = pad + "\t";
  if (typeof v === "string") {
    if (INVALID_XML.test(v)) throw new Error("plist string contains a character XML cannot represent");
    return `${pad}<string>${esc(v)}</string>`;
  }
  if (typeof v === "boolean") return `${pad}<${v}/>`;
  if (typeof v === "number") {
    if (!Number.isSafeInteger(v)) throw new Error("plist writer supports safe integers only");
    return `${pad}<integer>${v}</integer>`;
  }
  if (Array.isArray(v)) return v.length ? `${pad}<array>\n${v.map((x: unknown) => node(x, inner)).join("\n")}\n${pad}</array>` : `${pad}<array/>`;
  if (v && typeof v === "object") {
    const entries = Object.entries(v).filter(([, x]) => x !== undefined);
    if (!entries.length) return `${pad}<dict/>`;
    return `${pad}<dict>\n${entries.map(([k, x]) => `${inner}<key>${esc(k)}</key>\n${node(x, inner)}`).join("\n")}\n${pad}</dict>`;
  }
  throw new Error(`plist writer cannot encode ${v === null ? "null" : typeof v}`);
}

/** Serialize to an XML plist document. */
export function toXmlPlist(root: unknown): string {
  return (
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0">\n' +
    node(root, "") +
    "\n</plist>\n"
  );
}
