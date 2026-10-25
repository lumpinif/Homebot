// Shortcut action graphs (DESIGN §7.1). Same three actions as the spike's working v3:
// Ask for Input -> Get Contents of URL (POST JSON + token header) -> Speak Text.
// Pure functions: plist objects in, no I/O. The token ends up inside the result, so the
// serialized file is a secret artifact.
import { randomUUID } from "node:crypto";
import { CONVERSATION_STEPS } from "../core/conversation.ts";

/** One Shortcuts action as stored in the plist. */
export interface Action {
  WFWorkflowActionIdentifier: string;
  WFWorkflowActionParameters: Record<string, unknown>;
}

export interface Workflow {
  WFWorkflowActions: Action[];
  [key: string]: unknown;
}

const uuid = (): string => randomUUID().toUpperCase();

const text = (s: string) => ({ Value: { string: s }, WFSerializationType: "WFTextTokenString" });

/** Reference to an earlier action's output. */
const output = (outUuid: string, outName: string) => ({
  Value: { string: "￼", attachmentsByRange: { "{0, 1}": { OutputUUID: outUuid, OutputName: outName, Type: "ActionOutput" } } },
  WFSerializationType: "WFTextTokenString",
});

const dict = (items: [string, unknown][]) => ({
  Value: { WFDictionaryFieldValueItems: items.map(([k, v]) => ({ WFItemType: 0, WFKey: text(k), WFValue: v })) },
  WFSerializationType: "WFDictionaryFieldValue",
});

function workflow(actions: Action[]): Workflow {
  return {
    WFWorkflowActions: actions,
    WFWorkflowClientVersion: "2607.0.2",
    WFWorkflowMinimumClientVersion: 900,
    WFWorkflowMinimumClientVersionString: "900",
    WFWorkflowIcon: { WFWorkflowIconStartColor: 4282601983, WFWorkflowIconGlyphNumber: 59511 },
    WFWorkflowImportQuestions: [],
    WFWorkflowInputContentItemClasses: [],
    WFWorkflowOutputContentItemClasses: [],
    WFWorkflowTypes: [],
    WFWorkflowHasShortcutInputVariables: false,
    WFWorkflowHasOutputFallback: false,
    WFQuickActionSurfaces: [],
  };
}

const speak = (srcUuid: string, speakLang: string): Action => ({
  WFWorkflowActionIdentifier: "is.workflow.actions.speaktext",
  WFWorkflowActionParameters: { UUID: uuid(), WFText: output(srcUuid, "Contents of URL"), WFSpeakTextWait: true, WFSpeakTextLanguage: speakLang },
});

function checkBaseUrl(baseUrl: string): string {
  const u = new URL(baseUrl);
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("gateway URL must be http(s)");
  return u.origin;
}

/** The voice Shortcut for one bot. */
export function buildAskShortcut({ baseUrl, botKey, token, prompt, speakLang }: { baseUrl: string; botKey: string; token: string; prompt: string; speakLang: string }): Workflow {
  const origin = checkBaseUrl(baseUrl);
  const ask = uuid();
  const dl = uuid();
  return workflow([
    { WFWorkflowActionIdentifier: "is.workflow.actions.ask", WFWorkflowActionParameters: { UUID: ask, WFAskActionPrompt: prompt, WFInputType: "Text" } },
    {
      WFWorkflowActionIdentifier: "is.workflow.actions.downloadurl",
      WFWorkflowActionParameters: {
        UUID: dl,
        WFURL: `${origin}/v1/ask`,
        WFHTTPMethod: "POST",
        ShowHeaders: true,
        WFHTTPHeaders: dict([
          ["X-Homebot-Token", text(token)],
          ["Content-Type", text("application/json")],
        ]),
        WFHTTPBodyType: "JSON",
        WFJSONValues: dict([
          ["bot", text(botKey)],
          ["text", output(ask, "Provided Input")],
          ["v", text("1")],
        ]),
      },
    },
    speak(dl, speakLang),
  ]);
}

/**
 * Wait-limit probe (DESIGN §12, device session D1): GET /v1/probe-wait, which answers after
 * a growing delay; Siri speaks how long it waited, so the longest spoken value is the limit.
 */
export function buildProbeShortcut({ baseUrl, token, speakLang }: { baseUrl: string; token: string; speakLang: string }): Workflow {
  const origin = checkBaseUrl(baseUrl);
  const dl = uuid();
  return workflow([
    {
      WFWorkflowActionIdentifier: "is.workflow.actions.downloadurl",
      WFWorkflowActionParameters: { UUID: dl, WFURL: `${origin}/v1/probe-wait`, WFHTTPMethod: "GET", ShowHeaders: true, WFHTTPHeaders: dict([["X-Homebot-Token", text(token)]]) },
    },
    speak(dl, speakLang),
  ]);
}

// Loop building blocks (DESIGN §18.2, §19.1). Identifiers and keys follow the ScPL action
// definitions (MIT) and the ShortcutsBench parameter extract (Apache-2.0); identifiers only, no
// code copied. The If input was checked against a Shortcut exported by Shortcuts on macOS 26.

/** A named variable inside a text field. */
const varText = (name: string) => ({
  Value: { string: "￼", attachmentsByRange: { "{0, 1}": { Type: "Variable", VariableName: name } } },
  WFSerializationType: "WFTextTokenString",
});

/**
 * A named variable read as Text ("Get: Text" in the editor). An If on a plain Dictionary Value
 * variable offers only "has any value" on iOS/macOS 26, so "is"/"is not" lose their value and the
 * Shortcut stops with "Please choose a value for each parameter" (DESIGN §18.2).
 */
const varInputAsText = (name: string) => ({
  Value: { Aggrandizements: [{ CoercionItemClass: "WFStringContentItem", Type: "WFCoercionVariableAggrandizement" }], Type: "Variable", VariableName: name },
  WFSerializationType: "WFTextTokenAttachment",
});

/** An earlier action's output as an action's whole input. */
const outInput = (outUuid: string, outName: string) => ({ Value: { Type: "ActionOutput", OutputUUID: outUuid, OutputName: outName }, WFSerializationType: "WFTextTokenAttachment" });

const setVar = (name: string, input: unknown): Action => ({
  WFWorkflowActionIdentifier: "is.workflow.actions.setvariable",
  WFWorkflowActionParameters: { UUID: uuid(), WFVariableName: name, WFInput: input },
});

/** Get Dictionary Value `key` from the response of action `dl`, stored in variable `key`. */
function field(dl: string, key: string): Action[] {
  const id = uuid();
  return [
    {
      WFWorkflowActionIdentifier: "is.workflow.actions.getvalueforkey",
      WFWorkflowActionParameters: { UUID: id, WFInput: outInput(dl, "Contents of URL"), WFDictionaryKey: key, WFGetDictionaryValueType: "Value" },
    },
    setVar(key, outInput(id, "Dictionary Value")),
  ];
}

/** WFCondition codes: 4 "is", 5 "is not". */
function ifVar(name: string, condition: 4 | 5, value: string, then: Action[], otherwise?: Action[]): Action[] {
  const group = uuid();
  const mode = (m: 0 | 1 | 2, extra: Record<string, unknown> = {}): Action => ({
    WFWorkflowActionIdentifier: "is.workflow.actions.conditional",
    WFWorkflowActionParameters: { UUID: uuid(), GroupingIdentifier: group, WFControlFlowMode: m, ...extra },
  });
  return [
    mode(0, { WFCondition: condition, WFConditionalActionString: value, WFInput: { Type: "Variable", Variable: varInputAsText(name) } }),
    ...then,
    ...(otherwise ? [mode(1), ...otherwise] : []),
    mode(2),
  ];
}

function repeat(count: number, body: Action[]): Action[] {
  const group = uuid();
  return [
    { WFWorkflowActionIdentifier: "is.workflow.actions.repeat.count", WFWorkflowActionParameters: { UUID: uuid(), GroupingIdentifier: group, WFControlFlowMode: 0, WFRepeatCount: count } },
    ...body,
    { WFWorkflowActionIdentifier: "is.workflow.actions.repeat.count", WFWorkflowActionParameters: { UUID: uuid(), GroupingIdentifier: group, WFControlFlowMode: 2 } },
  ];
}

const speakVar = (name: string, speakLang: string): Action => ({
  WFWorkflowActionIdentifier: "is.workflow.actions.speaktext",
  WFWorkflowActionParameters: { UUID: uuid(), WFText: varText(name), WFSpeakTextWait: true, WFSpeakTextLanguage: speakLang },
});

/** Ask for Input whose question is variable `prompt`; the answer goes to variable `heard`. */
function askInto(prompt: string): Action[] {
  const id = uuid();
  return [
    { WFWorkflowActionIdentifier: "is.workflow.actions.ask", WFWorkflowActionParameters: { UUID: id, WFAskActionPrompt: varText(prompt), WFInputType: "Text" } },
    setVar("heard", outInput(id, "Provided Input")),
  ];
}

const exit = (): Action => ({ WFWorkflowActionIdentifier: "is.workflow.actions.exit", WFWorkflowActionParameters: { UUID: uuid() } });

/** Speak `say` and stop unless the gateway said to keep listening. */
const endUnlessListen = (speakLang: string): Action[] => ifVar("next", 5, "listen", [speakVar("say", speakLang), exit()]);

/** Number of steps in a lab run; the gateway ends the run on this step at the latest. */
export const LAB_STEPS = 10;

/**
 * A looping Shortcut (DESIGN §18.2, §19.1): a start POST (step 0), then up to `steps`
 * listen-and-POST steps. Each JSON response names how to speak `say`: V1 = Speak Text, then Ask
 * for Input with `ask`; V2 = Ask for Input with `say` as the question. The run ends when `next`
 * is not "listen". `fields` are sent with every POST (e.g. the bot), `startFields` with step 0.
 */
function buildLoopShortcut({ url, token, speakLang, steps, fields: extra = [], startFields = [] }: {
  url: string;
  token: string;
  speakLang: string;
  steps: number;
  fields?: [string, unknown][];
  startFields?: [string, unknown][];
}): Workflow {
  const post = (id: string, body: [string, unknown][]): Action => ({
    WFWorkflowActionIdentifier: "is.workflow.actions.downloadurl",
    WFWorkflowActionParameters: {
      UUID: id,
      WFURL: url,
      WFHTTPMethod: "POST",
      ShowHeaders: true,
      WFHTTPHeaders: dict([
        ["X-Homebot-Token", text(token)],
        ["Content-Type", text("application/json")],
      ]),
      WFHTTPBodyType: "JSON",
      WFJSONValues: dict(body),
    },
  });
  const fields = (dl: string) => ["say", "ask", "mode", "next"].flatMap((k) => field(dl, k));
  const start = uuid();
  const step = uuid();
  return workflow([
    post(start, [["v", text("2")], ...extra, ["step", text("0")], ["run", text("")], ["last", text(String(steps))], ["text", text("")], ...startFields]),
    ...fields(start),
    ...field(start, "run"),
    ...endUnlessListen(speakLang),
    ...repeat(steps, [
      ...ifVar("mode", 4, "v2", askInto("say"), [speakVar("say", speakLang), ...askInto("ask")]),
      post(step, [["v", text("2")], ...extra, ["run", varText("run")], ["step", varText("Repeat Index")], ["last", text(String(steps))], ["text", varText("heard")]]),
      ...fields(step),
      ...endUnlessListen(speakLang),
    ]),
    speakVar("say", speakLang),
  ]);
}

/** The lab Shortcut (DESIGN §19.1): the loop against /v1/lab. */
export function buildLabShortcut({ baseUrl, token, speakLang }: { baseUrl: string; token: string; speakLang: string }): Workflow {
  return buildLoopShortcut({ url: `${checkBaseUrl(baseUrl)}/v1/lab`, token, speakLang, steps: LAB_STEPS });
}

/**
 * The conversation Shortcut (DESIGN §18.2): the same loop against /v1/ask with `v: "2"`. Step 0
 * sends the Shortcut's own question, which the gateway returns as the first prompt (V2), so the
 * first thing Siri says is the familiar question; answers then use V1 (Speak Text, then "还有吗？").
 */
export function buildConversationShortcut({ baseUrl, botKey, token, prompt, speakLang }: { baseUrl: string; botKey: string; token: string; prompt: string; speakLang: string }): Workflow {
  return buildLoopShortcut({
    url: `${checkBaseUrl(baseUrl)}/v1/ask`,
    token,
    speakLang,
    steps: CONVERSATION_STEPS,
    fields: [["bot", text(botKey)]],
    startFields: [["prompt", text(prompt)]],
  });
}
