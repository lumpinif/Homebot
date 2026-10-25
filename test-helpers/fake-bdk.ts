// In-process fake of the Grok Bot sessions API, shaped like the real one as observed in the
// spike: numeric seq/updatedSeq as strings, 200 entries per page, `duplicate` on a reused messageId.
import http from "node:http";
import type { AddressInfo } from "node:net";

export const FAKE_KEY = "test-key-not-a-secret";

export interface FakeEntry {
  seq: string;
  updatedSeq: string;
  createdAtMs: number;
  kind: string;
  role?: string | undefined;
  text?: string | undefined;
}

export interface FakeSession {
  entries: FakeEntry[];
  idle: boolean;
  ids: Set<string>;
  queued?: number;
  /** A turn is running (autoReply sets this from the message until its last delivery). */
  working?: boolean;
}

export interface FakeMessage {
  messageId: string;
  text: string;
}

/** What `intercept` may do to a request: drop the connection, answer with a status, or (for a
 * message POST) store the message and then drop the connection. */
export type InterceptAction = "destroy" | "accept-then-destroy" | { status: number } | undefined;
export type Intercept = (r: { method: string | undefined; what: string; sid?: string; attempt?: number }) => Promise<InterceptAction>;

export interface FakeBdk {
  posts: (FakeMessage & { sid: string })[];
  requests: { method: string | undefined; path: string; auth: string | undefined; client: string | string[] | undefined }[];
  /** Optional hook, consulted before each request is handled. */
  intercept: Intercept | null | undefined;
  /** Optional: called after a new message is stored. */
  onMessage: ((sid: string, msg: FakeMessage) => void) | null | undefined;
  session(sid: string): FakeSession;
  add(sid: string, entry: { kind: string; role?: string | undefined; text?: string | undefined; createdAtMs?: number }): FakeEntry;
  /** Re-update an old entry (it comes back with a new updatedSeq). */
  touch(sid: string, seq: string, patch?: Partial<FakeEntry>): void;
  setIdle(sid: string, idle: boolean): void;
  /** Exact name -> { sid, createdAtMs }, for get-or-create by name. */
  names: Map<string, { sid: string; createdAtMs: number }>;
  /** An existing named bot (created long ago unless `createdAtMs` is given). */
  addNamed(name: string, sid: string, o?: { createdAtMs?: number }): void;
  /** Names that POST /sessions created (i.e. typos). */
  created: string[];
  /**
   * Reply as the bot `ms` after each new message, echoing the request tag if `echo`. `more`
   * are further deliveries of the same turn, `gapMs` apart. While the turn runs, `turn` reports
   * `{idle: false, inFlight: true}` (assumed real behavior, unverified live) unless
   * `reportsBusy` is false; it goes idle `settleMs` after the last delivery. `text` may be a
   * function of the message Homebot sent, for replies that fit the question.
   */
  autoReply(sid: string, o?: { ms?: number; text?: string | ((message: string) => string); echo?: boolean; more?: string[]; gapMs?: number; settleMs?: number; reportsBusy?: boolean }): void;
  /** `delivery` value answered for new messages (default `accepted_temporal`). */
  delivery: string | undefined;
  baseUrl: string;
  close(): Promise<void>;
}

export async function startFakeBdk(): Promise<FakeBdk> {
  let counter = 1000;
  const sessions = new Map<string, FakeSession>();
  const fake: FakeBdk = {
    posts: [],
    requests: [],
    intercept: null,
    onMessage: null,
    session(sid) {
      let s = sessions.get(sid);
      if (!s) sessions.set(sid, (s = { entries: [], idle: true, ids: new Set() }));
      return s;
    },
    add(sid, entry) {
      const seq = String(++counter);
      const e = { seq, updatedSeq: seq, createdAtMs: Date.now(), ...entry };
      fake.session(sid).entries.push(e);
      return e;
    },
    touch(sid, seq, patch = {}) {
      const e = fake.session(sid).entries.find((x) => x.seq === seq);
      if (!e) throw new Error(`fake: no entry ${seq} in session ${sid}`);
      Object.assign(e, patch, { updatedSeq: String(++counter) });
    },
    setIdle(sid, idle) {
      fake.session(sid).idle = idle;
    },
    names: new Map(),
    addNamed(name, sid, { createdAtMs = Date.now() - 86_400_000 } = {}) {
      fake.session(sid);
      fake.names.set(name, { sid, createdAtMs });
    },
    created: [],
    autoReply(sid, { ms = 20, text = "现在三点。", echo = true, more = [], gapMs = 20, settleMs = 0, reportsBusy = true } = {}) {
      fake.onMessage = (s, msg) => {
        if (s !== sid) return;
        const id = /hb:([0-9a-f]{12})/.exec(msg.text)?.[1];
        const session = fake.session(sid);
        if (reportsBusy) session.working = true;
        const reply = typeof text === "function" ? text(msg.text) : text;
        setTimeout(() => fake.add(sid, { kind: "send-message", text: echo ? `[hb:${id}] ${reply}` : reply }), ms);
        more.forEach((t, i) => setTimeout(() => fake.add(sid, { kind: "send-message", text: t }), ms + gapMs * (i + 1)));
        setTimeout(() => (session.working = false), ms + gapMs * more.length + settleMs);
      };
    },
    delivery: "accepted_temporal",
    baseUrl: "", // set once listening
    close: async () => {},
  };

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    const m = /^\/v0\/grokbot\/sessions\/([^/]+)\/(entries|messages)$/.exec(url.pathname);
    const send = (status: number, obj: unknown): void => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    let body = "";
    for await (const c of req as AsyncIterable<Buffer>) body += c; // no encoding set: Buffer chunks
    fake.requests.push({ method: req.method, path: url.pathname, auth: req.headers.authorization, client: req.headers["x-cursor-client-type"] });
    if (req.headers.authorization !== `Bearer ${FAKE_KEY}`) return send(401, { error: "unauthorized" });
    if (url.pathname === "/v0/grokbot/sessions" && req.method === "POST") {
      // Get-or-create by exact name, like the real route: an unknown name creates an empty bot.
      const act = fake.intercept ? await fake.intercept({ method: "POST", what: "sessions" }) : undefined;
      if (typeof act === "object") return send(act.status, { error: "injected" });
      // Test input: the client under test sends { name }.
      const { name } = JSON.parse(body || "{}") as { name: string };
      let named = fake.names.get(name);
      if (!named) {
        fake.names.set(name, (named = { sid: String(900000 + fake.names.size), createdAtMs: Date.now() }));
        fake.created.push(name);
      }
      const { sid, createdAtMs } = named;
      const es = fake.session(sid).entries;
      const latest = es.length ? es.map((e) => BigInt(e.updatedSeq)).reduce((a, b) => (a > b ? a : b)).toString() : "-1";
      return send(200, { id: Number(sid), name, createdAtMs, latestUpdatedSeq: latest });
    }
    if (!m) return send(404, { error: "not found" });
    const sid = m[1] ?? "";
    const what = m[2] ?? "";
    const attempt = fake.requests.filter((r) => r.path === url.pathname && r.method === req.method).length;
    const act = fake.intercept ? await fake.intercept({ method: req.method, sid, what, attempt }) : undefined;
    if (act === "destroy") return void req.socket.destroy();
    if (typeof act === "object") return send(act.status, { error: "injected" });
    const s = fake.session(sid);

    if (what === "entries" && req.method === "GET") {
      const after = BigInt(url.searchParams.get("afterUpdatedSeq") ?? "-1");
      const page = s.entries
        .filter((e) => BigInt(e.updatedSeq) > after)
        .sort((a, b) => (BigInt(a.updatedSeq) < BigInt(b.updatedSeq) ? -1 : 1))
        .slice(0, 200)
        .map((e) => ({ ...e }));
      return send(200, {
        entries: page,
        latestUpdatedSeq: page.at(-1)?.updatedSeq ?? String(after),
        // Real shape (probe P1). Values during a running turn are assumed, not yet seen live.
        turn: { idle: s.idle && !s.working, inFlight: !s.idle || !!s.working, queued: s.queued ?? 0 },
      });
    }
    if (what === "messages" && req.method === "POST") {
      // Test input: the client under test sends { messageId, text }.
      const msg = JSON.parse(body) as FakeMessage;
      if (s.ids.has(msg.messageId)) return send(200, { delivery: "duplicate" });
      s.ids.add(msg.messageId);
      fake.posts.push({ sid, ...msg });
      fake.add(sid, { kind: "message", role: "user", text: msg.text });
      fake.onMessage?.(sid, msg);
      if (act === "accept-then-destroy") return void req.socket.destroy();
      return send(200, fake.delivery === undefined ? {} : { delivery: fake.delivery });
    }
    return send(405, { error: "method" });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  // Listening on TCP (above), so address() is an AddressInfo, never a pipe name or null.
  fake.baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v0/grokbot/sessions`;
  fake.close = () => {
    server.closeAllConnections();
    return new Promise<void>((r) => server.close(() => r()));
  };
  return fake;
}
