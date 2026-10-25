// Device-experiment mode (DESIGN §19): scripted steps for the lab Shortcut, served on /v1/lab
// only while `homebot start --lab` runs. It never contacts a bot. What Felix says is matched
// against the expected sentence and then discarded: the log holds ids, lengths, match results
// and timings only (design review v8 B3).
import { setTimeout as sleep } from "node:timers/promises";
import { isRecord, readJson, writeJson } from "./fsutil.ts";
import { isRunId, RunStore, type LoopResponse } from "./runs.ts";
import type { ReplyLang } from "./lang.ts";
import type { Log } from "./log.ts";

export const SCENARIOS = ["E1", "E1b", "E2", "E3", "E4", "E5", "E6", "E7"] as const;
export type ScenarioId = (typeof SCENARIOS)[number];
export const isScenario = (v: unknown): v is ScenarioId => typeof v === "string" && (SCENARIOS as readonly string[]).includes(v);

/** E7 answer delays (s) when `homebot lab use E7` names none. */
export const DEFAULT_DELAYS = [8, 12, 16, 20, 25, 30];

export type LabMode = LoopResponse["mode"];

/**
 * The lab is Felix's device-experiment tool and is scripted in English and Mandarin only; a lab
 * Shortcut made for any other Siri language runs in English.
 */
type LabLang = "en" | "zh-CN";
const labLang = (lang: ReplyLang): LabLang => (lang === "zh-CN" ? "zh-CN" : "en");

/** What the lab Shortcut hears when the gateway runs without `--lab`. */
export const labOff = (lang: ReplyLang): string => LAB_OFF[labLang(lang)];
const LAB_OFF: Record<LabLang, string> = {
  "zh-CN": "实验模式没有打开。请在 Mac 上用 homebot start --lab 启动。",
  en: "The lab is off. Start Homebot on the Mac with: homebot start --lab.",
};

export type LabResponse = LoopResponse;

interface Expect {
  /** The whole sentence; only this, in full, counts as "full". */
  whole: string;
  head: string;
  tail: string;
}

const word = (w: string): Expect => ({ whole: w, head: w, tail: w });

interface Spec {
  say: string;
  mode?: LabMode;
  /** What the user is asked to say in reply to this step. */
  expect?: Expect;
  delayMs?: number;
}

/**
 * full: the whole sentence arrived. cut: its start arrived, not the whole (cut off, or words
 * missing). partial: only its end arrived. other: neither.
 */
export type Match = "empty" | "full" | "cut" | "partial" | "other" | "n/a";

const norm = (s: string): string => s.normalize("NFKC").toLowerCase().replace(/[\p{P}\p{S}\s]/gu, "");

/** Did the received text contain the whole expected sentence, only its start, only its end, or neither? */
export function matchSentence(received: string, expect: Expect | undefined): Match {
  const r = norm(received);
  if (!r) return "empty";
  if (!expect) return "n/a";
  if (r.includes(norm(expect.whole))) return "full";
  if (r.includes(norm(expect.head))) return "cut";
  if (r.includes(norm(expect.tail))) return "partial";
  return "other";
}

interface Text {
  ask: string;
  pause: Expect;
  pauseRead: string;
  ok: Expect;
  no: Expect;
  /** The last word of a long answer; saying it back proves the whole answer was read. */
  marker: Expect;
  long: string;
  restart: string;
  done: (id: string) => string;
  waited: (n: number) => string;
  e1: [string, string];
  e1b: [string, string, string];
  e2: [string, string, string, string];
  e3: [string, string];
  e4: [string, string, string, string, string];
  e5: { first: string; answer: (n: number) => string; last: string };
  e6: [string, string];
  e7: string;
}

const LONG_ZH =
  "下面是一段比较长的回答，用来测试 Siri 能不能把它完整读出来。今天的天气总体不错，上午有一些云，中午以后会转晴，气温大约在二十度到二十六度之间，" +
  "傍晚可能会有一点风。如果你打算出门散步，下午四点以后比较合适，记得带一件薄外套。晚上的空气质量预计良好，适合开窗通风。明天的天气和今天差不多，" +
  "后天可能会有小雨，出门前最好再看一下预报。这段话到这里就结束了。";
const LONG_EN =
  "Here is a longer answer, to test whether Siri reads all of it. The weather today is mostly fine: some clouds in the morning, clearing after noon, " +
  "with temperatures between twenty and twenty-six degrees and a little wind in the evening. If you plan a walk, late afternoon is best; bring a light jacket. " +
  "Air quality tonight should be good. Tomorrow looks similar, and there may be light rain the day after. That is the end of this answer.";

const TEXT: Record<LabLang, Text> = {
  "zh-CN": {
    ask: "请说。",
    pause: { whole: "明天我想去公园散步，然后去超市买菜", head: "明天我想去公园散步", tail: "然后去超市买菜" },
    pauseRead: "明天我想去公园散步，然后去超市买菜",
    ok: word("好"),
    no: word("不用了"),
    marker: word("西瓜"),
    long: LONG_ZH,
    restart: "这次实验已经结束了，请重新说“家庭实验”。",
    done: (id) => `实验${"一二三四五六七"[Number(id.slice(1, 2)) - 1] ?? id}${id.endsWith("b") ? "乙" : ""}结束。`,
    waited: (n) => `等了${n}秒。`,
    e1: ["实验一：这一轮请不要说话，等它自己结束。", "收到了空的回答，快捷指令没有自己结束。实验一结束。"],
    e1b: ["实验一乙：这一轮请说“好”。", "收到了。这一轮请不要说话，等它自己结束。", "收到了空的回答，快捷指令没有自己结束。实验一乙结束。"],
    e2: [
      "实验二，第一次：请正常读这句话，中间不要停：明天我想去公园散步，然后去超市买菜。",
      "第二次：同一句话，在“散步”后面停一秒。",
      "第三次：在“散步”后面停三秒。",
      "第四次：在“散步”后面停六秒。",
    ],
    e3: ["实验三：先按住 HomePod 顶部不放，再读这句话，在“散步”后面停两秒，说完再松手：明天我想去公园散步，然后去超市买菜。", "再来一次，同样按住。"],
    e4: [
      "实验四，第一部分：这是一句短回答。听完请说“好”。",
      "这是一句短回答，作为提问读出来。听完请说“好”。",
      `${LONG_ZH}最后一个词是西瓜。请说出最后一个词。`,
      `${LONG_ZH}这一段是作为提问读出来的。最后一个词是西瓜。请说出最后一个词。`,
      `${LONG_ZH}${LONG_ZH}这一段更长，作为提问读出来。最后一个词是西瓜。请说出最后一个词。`,
    ],
    e5: { first: "实验五：一次长一点的对话，一共六轮。每轮随便说一句话。", answer: (n) => `这是第${n}轮的回答，模拟机器人想了八秒。请再随便说一句。`, last: "这是最后一轮的回答。实验五结束。" },
    e6: ["实验六：请回答“不用了”。", "收到了“不用了”，快捷指令没有自己结束。实验六结束。"],
    e7: "实验七：随便说一句话，然后等着。",
  },
  en: {
    ask: "Go ahead.",
    pause: { whole: "tomorrow I want to walk in the park and then buy some groceries", head: "tomorrow I want to walk in the park", tail: "buy some groceries" },
    pauseRead: "tomorrow I want to walk in the park and then buy some groceries",
    ok: word("okay"),
    no: word("no"),
    marker: word("watermelon"),
    long: LONG_EN,
    restart: "This test run has ended. Please say the lab phrase again.",
    done: (id) => `Test ${["one", "two", "three", "four", "five", "six", "seven"][Number(id.slice(1, 2)) - 1] ?? id}${id.endsWith("b") ? " B" : ""} is done.`,
    waited: (n) => `Waited ${n} seconds.`,
    e1: ["Test one: say nothing this time, and let it end by itself.", "An empty answer arrived, and the Shortcut didn't stop by itself. Test one is done."],
    e1b: ["Test one B: say okay this time.", "Got it. Now say nothing, and let it end by itself.", "An empty answer arrived, and the Shortcut didn't stop by itself. Test one B is done."],
    e2: [
      "Test two, first try: read this without a pause: tomorrow I want to walk in the park, and then buy some groceries.",
      "Second try: the same sentence, with a one-second pause after park.",
      "Third try: a three-second pause after park.",
      "Fourth try: a six-second pause after park.",
    ],
    e3: ["Test three: press and hold the top of the HomePod, then read the sentence with a two-second pause after park, and let go when done: tomorrow I want to walk in the park, and then buy some groceries.", "Once more, holding the top."],
    e4: [
      "Test four, part one: this is a short answer. Say okay when you've heard it.",
      "This is a short answer, read as the question. Say okay when you've heard it.",
      `${LONG_EN} The last word is watermelon. Say the last word.`,
      `${LONG_EN} This one was read as the question. The last word is watermelon. Say the last word.`,
      `${LONG_EN} ${LONG_EN} This even longer one was read as the question. The last word is watermelon. Say the last word.`,
    ],
    e5: { first: "Test five: a longer conversation, six turns. Say anything each time.", answer: (n) => `This is answer ${n}; the bot took eight seconds. Say anything again.`, last: "This is the last answer. Test five is done." },
    e6: ["Test six: please answer no.", "I got your no, so the Shortcut didn't stop by itself. Test six is done."],
    e7: "Test seven: say anything, then wait.",
  },
};

/** The steps of one scenario: specs[0] answers the start step, specs[k] answers step k. */
function scenario(id: ScenarioId, lang: ReplyLang, delaySec: number): Spec[] {
  const t = TEXT[labLang(lang)];
  const done = { say: t.done(id) };
  switch (id) {
    // E1 and E1b are separate runs: if silence stops the Shortcut, the first run cannot reach a
    // second condition (milestone review S5).
    case "E1":
      return [{ say: t.e1[0] }, { say: t.e1[1] }];
    case "E1b":
      return [{ say: t.e1b[0], expect: t.ok }, { say: t.e1b[1] }, { say: t.e1b[2] }];
    case "E2":
      return [{ say: t.e2[0], expect: t.pause }, { say: t.e2[1], expect: t.pause }, { say: t.e2[2], expect: t.pause }, { say: t.e2[3], expect: t.pause }, done];
    case "E3":
      return [{ say: t.e3[0], expect: t.pause }, { say: t.e3[1], expect: t.pause }, done];
    case "E4":
      return [
        { say: t.e4[0], mode: "v1", expect: t.ok },
        { say: t.e4[1], mode: "v2", expect: t.ok },
        { say: t.e4[2], mode: "v1", expect: t.marker },
        { say: t.e4[3], mode: "v2", expect: t.marker },
        { say: t.e4[4], mode: "v2", expect: t.marker },
        done,
      ];
    case "E5":
      return [{ say: t.e5.first }, ...Array.from({ length: 5 }, (_, i) => ({ say: t.e5.answer(i + 1), delayMs: 8000 })), { say: t.e5.last, delayMs: 8000 }];
    case "E6":
      return [{ say: t.e6[0], expect: t.no }, { say: t.e6[1] }];
    case "E7":
      return [{ say: t.e7 }, { say: t.waited(delaySec), delayMs: delaySec * 1000 }];
  }
}

export interface LabState {
  scenario: ScenarioId;
  /** Changes on every `lab use`; the gateway restarts the E7 delay list when it does. */
  version: number;
  delays: number[];
}

export async function readLabState(file: string): Promise<LabState> {
  const raw = await readJson(file, {});
  const r = isRecord(raw) ? raw : {};
  const delays = Array.isArray(r.delays) && r.delays.every((d) => Number.isInteger(d) && d > 0 && d <= 120) ? (r.delays as number[]) : DEFAULT_DELAYS; // checked element by element above
  return { scenario: isScenario(r.scenario) ? r.scenario : "E1", version: typeof r.version === "number" ? r.version : 0, delays };
}

export async function writeLabState(file: string, s: { scenario: ScenarioId; delays?: number[] | undefined }, now = Date.now()): Promise<void> {
  await writeJson(file, { scenario: s.scenario, version: now, delays: s.delays ?? DEFAULT_DELAYS });
}

interface RunState {
  scenario: ScenarioId;
  specs: Spec[];
  /** The Shortcut's step cap, as sent at the start; later steps cannot change it. */
  last: number;
  /** When the previous response was ready (for the gap to the next step). */
  sentAt: number;
}

export interface LabStep {
  run: string;
  step: number;
  last: number;
  text: string;
  tokenId: string;
  lang: ReplyLang;
  signal?: AbortSignal | undefined;
}

export class LabService {
  runs: RunStore<RunState>;
  file: string;
  log: Log;
  now: () => number;
  /** Scale for scripted delays (tests use a small value). */
  delayUnit: number;
  #version = -1;
  #delayIdx = 0;

  constructor({ file, log = () => {}, now = Date.now, delayUnit = 1 }: { file: string; log?: Log; now?: () => number; delayUnit?: number }) {
    this.file = file;
    this.log = log;
    this.now = now;
    this.delayUnit = delayUnit;
    this.runs = new RunStore<RunState>({ now });
  }

  async handle({ run, step, last, text, tokenId, lang, signal }: LabStep): Promise<LabResponse> {
    const t = TEXT[labLang(lang)];
    if (step === 0) {
      const st = await readLabState(this.file);
      if (st.version !== this.#version) {
        this.#version = st.version;
        this.#delayIdx = 0;
      }
      const delay = st.delays[this.#delayIdx++ % st.delays.length] ?? 8;
      const specs = scenario(st.scenario, lang, delay);
      const state: RunState = { scenario: st.scenario, specs, last, sentAt: this.now() };
      const end = specs.length <= 1 || last <= 0;
      const started = this.runs.start(tokenId, state, async (id) => this.#respond(specs[0], id, t, end));
      if (end) this.runs.finish(started.id);
      this.log({ event: "lab", scenario: st.scenario, run: started.id.slice(0, 6), step: 0 });
      return started.response;
    }
    // Only an id this gateway could have issued is looked up or logged (milestone review S6).
    if (!isRunId(run)) {
      this.log({ event: "lab", run: "invalid", step, unknown: true });
      return { say: t.restart, ask: t.ask, mode: "v1", next: "end", run: "" };
    }
    const c = this.runs.check(run, tokenId, step);
    if (c.kind === "repeat") {
      this.log({ event: "lab", run: run.slice(0, 6), step, repeat: true });
      return c.response as Promise<LabResponse>; // the stored response of this run's own step
    }
    if (c.kind !== "next") {
      this.log({ event: "lab", run: run.slice(0, 6), step, unknown: c.kind });
      return { say: t.restart, ask: t.ask, mode: "v1", next: "end", run };
    }
    const s = c.state;
    return this.runs.take(run, step, async () => {
      const prev = s.specs[step - 1];
      const spec = s.specs[step] ?? { say: t.done(s.scenario) };
      const entry: Record<string, unknown> = {
        event: "lab",
        scenario: s.scenario,
        run: run.slice(0, 6),
        step,
        mode: prev?.mode ?? "v1",
        recv_len: [...text.trim()].length,
        match: matchSentence(text, prev?.expect),
        gap_ms: this.now() - s.sentAt,
      };
      // `text` is not used after this point and never logged.
      const end = step >= s.specs.length - 1 || step >= s.last;
      if (end) this.runs.finish(run);
      if (spec.delayMs) {
        const t0 = this.now();
        await sleep(spec.delayMs * this.delayUnit, undefined, { signal }).catch(() => {});
        entry.delay_ms = spec.delayMs;
        if (signal?.aborted) entry.client_gave_up_ms = this.now() - t0;
      }
      this.log(entry);
      s.sentAt = this.now();
      return this.#respond(spec, run, t, end);
    });
  }

  #respond(spec: Spec | undefined, run: string, t: Text, end: boolean): LabResponse {
    return { say: spec?.say ?? "", ask: t.ask, mode: spec?.mode ?? "v1", next: end ? "end" : "listen", run };
  }
}
