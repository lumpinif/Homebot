// A standalone fake Grok Bot API on loopback, for smoke runs of the Swift gateway (never a real
// bot). It holds one bot conversation, session 14752726 named "homebot" (so it can be added by
// name), that answers every message with an echoed reply that fits the question and its language
// (so dev screenshots read like real use), and a quiet second bot, session 555 named "Kitchen",
// for the one-phrase Shortcut's menu. Prints its base URL, then serves until Ctrl-C.
// Usage: node scripts/fake-grokbot.ts [reply text]   (a fixed reply for every message)
import { startFakeBdk, FAKE_KEY } from "../test-helpers/fake-bdk.ts";

const SID = "14752726";
const fake = await startFakeBdk();
fake.addNamed("homebot", SID);
for (let i = 0; i < 3; i++) fake.add(SID, { kind: "send-message", text: `old ${i}` });
fake.addNamed("Kitchen", "555");
fake.add("555", { kind: "send-message", text: "old" });
fake.autoReply(SID, { text: process.argv[2] ?? answer });
/**
 * A plausible spoken answer for the question in Homebot's message (line 2; line 1 carries the
 * reply language, e.g. `zh-CN`). Canned and offline: dev screenshots only, never a real bot.
 */
// A long answer, so Activity shows Show more.
const WEEKEND = {
  en: "Saturday looks dry until mid-afternoon, so go for the morning walk by the river first. Lunch at the noodle place you liked, then the market closes at four. Rain comes in the evening: a good night for the film you saved. Sunday is clear and mild; the bike path is open again, and the bakery opens at eight. Keep the evening free, because Monday starts early.",
  zh: "周六下午三点前都不会下雨，上午先去河边散步，中午去你喜欢的那家面馆，集市四点关门。傍晚开始下雨，适合在家看你收藏的那部电影。周日晴，气温舒适，自行车道已经重新开放，面包店八点开门。晚上早点休息，周一要早起。",
  hant: "週六下午三點前都不會下雨，上午先去河邊散步，中午去你喜歡的那家麵館，市集四點關門。傍晚開始下雨，適合在家看你收藏的那部電影。週日晴，氣溫舒適，自行車道已經重新開放，麵包店八點開門。晚上早點休息，週一要早起。",
};

function answer(message: string): string {
  const [head = "", question = ""] = message.split("\n");
  const lang = /· ([a-z]{2})(?:-[A-Za-z]+)?\]/.exec(head)?.[1] ?? (/[\u3400-\u9fff]/.test(question) ? "zh" : "en");
  const q = question.toLowerCase();
  const now = new Date();
  const hh = now.getHours();
  const mm = String(now.getMinutes()).padStart(2, "0");
  // Simplified Chinese, Traditional Chinese (zh-TW) or English; other languages get English.
  const zh = lang === "zh";
  const hant = zh && /zh-TW\]/.test(head);
  if (hant) {
    if (/幾點|時間/.test(q)) return `現在是${hh}點${mm}分。`;
    if (/下雨|天氣/.test(q)) return "明天多雲轉小雨，下午降雨機率大約百分之六十，出門記得帶傘。";
    if (/週末/.test(q)) return WEEKEND.hant;
    if (/笑話/.test(q)) return "為什麼工程師分不清萬聖節和聖誕節？因為 Oct 31 等於 Dec 25。";
    return `關於「${question.trim()}」：我查了一下，稍後把詳細內容傳到你的手機。`;
  }
  if (/time|几点|時間|时间/.test(q)) return zh ? `现在是${hh}点${mm}分。` : `It's ${hh % 12 || 12}:${mm} ${hh < 12 ? "AM" : "PM"}.`;
  if (/rain|weather|下雨|天气|天氣/.test(q))
    return zh ? "明天多云转小雨，下午降雨概率大约百分之六十，出门记得带伞。" : "Light rain is likely tomorrow afternoon, about a sixty percent chance. Take an umbrella.";
  if (/joke|笑话|笑話/.test(q))
    return zh ? "为什么程序员分不清万圣节和圣诞节？因为 Oct 31 等于 Dec 25。" : "Why do programmers mix up Halloween and Christmas? Because Oct 31 equals Dec 25.";
  if (/weekend|周末/.test(q)) return zh ? WEEKEND.zh : WEEKEND.en;
  if (/light|灯|燈/.test(q)) return zh ? "好的，客厅的灯已经关了。" : "Done. The living room lights are off.";
  return zh ? `关于“${question.trim()}”：我查了一下，稍后把详细内容发到你的手机上。` : `About "${question.trim()}": I looked into it and will send the details to your phone.`;
}

console.log(`fake Grok Bot API: ${fake.baseUrl} (session ${SID}, key "${FAKE_KEY}" is a test value)`);
const stop = async () => {
  console.log(`messages received: ${fake.posts.length}`);
  await fake.close();
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
