// Spoken system messages (DESIGN §10). Keep them short: Siri reads them aloud.
// One catalog per reply language (src/core/lang.ts). The non-English, non-Mandarin catalogs are
// Claude's drafts, cross-checked with Grok; no native speaker has reviewed them yet (STATUS).
import type { ReplyLang } from "./lang.ts";

export type Lang = ReplyLang;

export interface Messages {
  busy(bot: string): string;
  inFlight(bot: string): string;
  notSent(): string;
  noReplyInTime(bot: string): string;
  refused(): string;
  unspeakable(): string;
  /** The reply is (mostly) in a script the Shortcut's voice can't read (DECISIONS item 39). */
  wrongScript(): string;
  emptyQuestion(): string;
  tooLong(): string;
  badToken(): string;
  forbiddenBot(): string;
  botNotConfigured(): string;
  authFailed(): string;
  upstreamDown(): string;
  rateLimited(): string;
  internalError(): string;
  /** Conversation mode (DESIGN §18.2): the short question after an answer. */
  more(): string;
  /** Conversation mode: the run ends on an end word or silence. */
  goodbye(): string;
  /** Conversation mode: an unknown, expired or out-of-order run. */
  restart(): string;
}

const zh: Messages = {
  busy: (bot) => `${bot}正在忙，请稍后再问。`,
  inFlight: (bot) => `${bot}还在回答上一个问题。`,
  notSent: () => "没来得及发送，请再问一次。",
  noReplyInTime: (bot) => `${bot}没有及时回复。问题可能已经送达，请在 Grok Bot 里查看，不要重复提问。`,
  refused: () => "收到了回复，但无法确认它是在回答这个问题，所以没有朗读。请在 Grok Bot 里查看。",
  unspeakable: () => "回复里没有可以朗读的文字，请在 Grok Bot 里查看。",
  wrongScript: () => "这条回答用的语言，这个快捷指令的语音读不了，请在 Grok Bot 里查看。",
  emptyQuestion: () => "没听清，请再说一次。",
  tooLong: () => "问题太长了，请说得简短一些。",
  badToken: () => "这个快捷指令已失效，请在 Homebot 里重新生成。",
  forbiddenBot: () => "这个快捷指令不能使用这个 bot。",
  botNotConfigured: () => "Homebot 还没有配置好这个 bot，请运行 homebot doctor。",
  authFailed: () => "Homebot 无法登录 Grok Bot，请检查设置。",
  upstreamDown: () => "Grok Bot 暂时连不上，请稍后再试。",
  rateLimited: () => "问得太频繁了，请稍等一下。",
  internalError: () => "Homebot 出错了，请稍后再试。",
  more: () => "还有吗？",
  goodbye: () => "好的。",
  restart: () => "我们重新开始吧，请再说一次快捷指令的名字。",
};

const en: Messages = {
  busy: (bot) => `${bot} is busy. Please ask again later.`,
  inFlight: (bot) => `${bot} is still answering the previous question.`,
  notSent: () => "That didn't get sent in time. Please ask again.",
  noReplyInTime: (bot) => `${bot} didn't reply in time. Your question may have been delivered; check the conversation in Grok Bot instead of asking again.`,
  refused: () => "A reply arrived, but Homebot can't confirm it answers this question, so it won't be read aloud. Please check Grok Bot.",
  unspeakable: () => "The reply has no text that can be read aloud. Please check Grok Bot.",
  wrongScript: () => "The answer is in a language this Shortcut's voice can't read. Please check Grok Bot.",
  emptyQuestion: () => "I didn't catch that. Please say it again.",
  tooLong: () => "That question is too long. Please keep it short.",
  badToken: () => "This shortcut no longer works. Please make a new one in Homebot.",
  forbiddenBot: () => "This shortcut isn't allowed to use that bot.",
  botNotConfigured: () => "Homebot isn't set up for this bot yet. Run homebot doctor.",
  authFailed: () => "Homebot can't sign in to Grok Bot. Please check the settings.",
  upstreamDown: () => "Grok Bot can't be reached right now. Please try again later.",
  rateLimited: () => "Too many questions in a row. Please wait a moment.",
  internalError: () => "Homebot ran into an error. Please try again later.",
  more: () => "Anything else?",
  goodbye: () => "Okay.",
  restart: () => "Let's start again: say the Shortcut's name again.",
};

const es: Messages = {
  busy: (bot) => `${bot} está ocupado. Vuelve a preguntar más tarde.`,
  inFlight: (bot) => `${bot} todavía está respondiendo a la pregunta anterior.`,
  notSent: () => "No se ha podido enviar a tiempo. Vuelve a preguntar.",
  noReplyInTime: (bot) => `${bot} no ha respondido a tiempo. Puede que la pregunta haya llegado; mira la conversación en Grok Bot en vez de volver a preguntar.`,
  refused: () => "Ha llegado una respuesta, pero Homebot no puede confirmar que sea de esta pregunta, así que no la leerá. Míralo en Grok Bot.",
  unspeakable: () => "La respuesta no tiene texto que se pueda leer en voz alta. Míralo en Grok Bot.",
  wrongScript: () => "La respuesta está en un idioma que la voz de este atajo no puede leer. Míralo en Grok Bot.",
  emptyQuestion: () => "No te he entendido. Repítelo, por favor.",
  tooLong: () => "La pregunta es demasiado larga. Hazla más corta.",
  badToken: () => "Este atajo ya no funciona. Crea uno nuevo en Homebot.",
  forbiddenBot: () => "Este atajo no puede usar ese bot.",
  botNotConfigured: () => "Homebot aún no está configurado para este bot. Ejecuta homebot doctor.",
  authFailed: () => "Homebot no puede iniciar sesión en Grok Bot. Revisa los ajustes.",
  upstreamDown: () => "Ahora mismo no se puede conectar con Grok Bot. Inténtalo más tarde.",
  rateLimited: () => "Demasiadas preguntas seguidas. Espera un momento.",
  internalError: () => "Homebot ha tenido un error. Inténtalo más tarde.",
  more: () => "¿Algo más?",
  goodbye: () => "Vale.",
  restart: () => "Empecemos de nuevo: vuelve a decir el nombre del atajo.",
};

const fr: Messages = {
  busy: (bot) => `${bot} est occupé. Reposez la question plus tard.`,
  inFlight: (bot) => `${bot} répond encore à la question précédente.`,
  notSent: () => "La question n’a pas pu être envoyée à temps. Reposez-la.",
  noReplyInTime: (bot) => `${bot} n’a pas répondu à temps. Votre question est peut-être arrivée : regardez la conversation dans Grok Bot plutôt que de la reposer.`,
  refused: () => "Une réponse est arrivée, mais Homebot ne peut pas confirmer qu’elle répond à cette question, donc elle ne sera pas lue. Regardez dans Grok Bot.",
  unspeakable: () => "La réponse ne contient aucun texte à lire à voix haute. Regardez dans Grok Bot.",
  wrongScript: () => "La réponse est dans une langue que la voix de ce raccourci ne sait pas lire. Regardez dans Grok Bot.",
  emptyQuestion: () => "Je n’ai pas compris. Pouvez-vous répéter ?",
  tooLong: () => "La question est trop longue. Faites plus court.",
  badToken: () => "Ce raccourci ne fonctionne plus. Créez-en un nouveau dans Homebot.",
  forbiddenBot: () => "Ce raccourci n’a pas le droit d’utiliser ce bot.",
  botNotConfigured: () => "Homebot n’est pas encore configuré pour ce bot. Lancez homebot doctor.",
  authFailed: () => "Homebot n’arrive pas à se connecter à Grok Bot. Vérifiez les réglages.",
  upstreamDown: () => "Grok Bot est injoignable pour le moment. Réessayez plus tard.",
  rateLimited: () => "Trop de questions d’affilée. Patientez un instant.",
  internalError: () => "Homebot a rencontré une erreur. Réessayez plus tard.",
  more: () => "Autre chose ?",
  goodbye: () => "D’accord.",
  restart: () => "Recommençons : redites le nom du raccourci.",
};

const de: Messages = {
  busy: (bot) => `${bot} ist gerade beschäftigt. Frag bitte später noch einmal.`,
  inFlight: (bot) => `${bot} beantwortet noch die vorherige Frage.`,
  notSent: () => "Das konnte nicht rechtzeitig gesendet werden. Frag bitte noch einmal.",
  noReplyInTime: (bot) => `${bot} hat nicht rechtzeitig geantwortet. Deine Frage ist vielleicht angekommen. Sieh in Grok Bot nach, statt noch einmal zu fragen.`,
  refused: () => "Eine Antwort ist da, aber Homebot kann nicht bestätigen, dass sie zu dieser Frage gehört. Deshalb wird sie nicht vorgelesen. Sieh bitte in Grok Bot nach.",
  unspeakable: () => "Die Antwort enthält keinen Text zum Vorlesen. Sieh bitte in Grok Bot nach.",
  wrongScript: () => "Die Antwort ist in einer Sprache, die die Stimme dieses Kurzbefehls nicht lesen kann. Sieh bitte in Grok Bot nach.",
  emptyQuestion: () => "Das habe ich nicht verstanden. Sag es bitte noch einmal.",
  tooLong: () => "Die Frage ist zu lang. Bitte fass dich kürzer.",
  badToken: () => "Dieser Kurzbefehl funktioniert nicht mehr. Erstelle in Homebot einen neuen.",
  forbiddenBot: () => "Dieser Kurzbefehl darf diesen Bot nicht verwenden.",
  botNotConfigured: () => "Homebot ist für diesen Bot noch nicht eingerichtet. Führe homebot doctor aus.",
  authFailed: () => "Homebot kann sich nicht bei Grok Bot anmelden. Prüf bitte die Einstellungen.",
  upstreamDown: () => "Grok Bot ist gerade nicht erreichbar. Versuch es später noch einmal.",
  rateLimited: () => "Zu viele Fragen hintereinander. Warte bitte einen Moment.",
  internalError: () => "In Homebot ist ein Fehler aufgetreten. Versuch es später noch einmal.",
  more: () => "Sonst noch etwas?",
  goodbye: () => "Okay.",
  restart: () => "Fangen wir neu an: Sag noch einmal den Namen des Kurzbefehls.",
};

const it: Messages = {
  busy: (bot) => `${bot} è occupato. Riprova più tardi.`,
  inFlight: (bot) => `${bot} sta ancora rispondendo alla domanda precedente.`,
  notSent: () => "Non è stato possibile inviarla in tempo. Riprova a chiedere.",
  noReplyInTime: (bot) => `${bot} non ha risposto in tempo. La domanda potrebbe essere arrivata: controlla la conversazione in Grok Bot invece di chiedere di nuovo.`,
  refused: () => "È arrivata una risposta, ma Homebot non può confermare che sia per questa domanda, quindi non la leggerà. Controlla in Grok Bot.",
  unspeakable: () => "La risposta non contiene testo da leggere ad alta voce. Controlla in Grok Bot.",
  wrongScript: () => "La risposta è in una lingua che la voce di questo comando rapido non sa leggere. Controlla in Grok Bot.",
  emptyQuestion: () => "Non ho capito. Puoi ripetere?",
  tooLong: () => "La domanda è troppo lunga. Prova a essere più breve.",
  badToken: () => "Questo comando rapido non funziona più. Creane uno nuovo in Homebot.",
  forbiddenBot: () => "Questo comando rapido non può usare quel bot.",
  botNotConfigured: () => "Homebot non è ancora configurato per questo bot. Esegui homebot doctor.",
  authFailed: () => "Homebot non riesce ad accedere a Grok Bot. Controlla le impostazioni.",
  upstreamDown: () => "Al momento Grok Bot non è raggiungibile. Riprova più tardi.",
  rateLimited: () => "Troppe domande di fila. Aspetta un momento.",
  internalError: () => "Si è verificato un errore in Homebot. Riprova più tardi.",
  more: () => "Altro?",
  goodbye: () => "Va bene.",
  restart: () => "Ricominciamo: ripeti il nome del comando rapido.",
};

const ptBR: Messages = {
  busy: (bot) => `${bot} está ocupado. Pergunte de novo mais tarde.`,
  inFlight: (bot) => `${bot} ainda está respondendo à pergunta anterior.`,
  notSent: () => "Não deu tempo de enviar. Pergunte de novo.",
  noReplyInTime: (bot) => `${bot} não respondeu a tempo. Sua pergunta pode ter chegado; confira a conversa no Grok Bot em vez de perguntar de novo.`,
  refused: () => "Chegou uma resposta, mas o Homebot não consegue confirmar que ela é desta pergunta, então ela não será lida. Confira no Grok Bot.",
  unspeakable: () => "A resposta não tem texto que possa ser lido em voz alta. Confira no Grok Bot.",
  wrongScript: () => "A resposta está em um idioma que a voz deste atalho não consegue ler. Confira no Grok Bot.",
  emptyQuestion: () => "Não entendi. Pode repetir?",
  tooLong: () => "A pergunta está longa demais. Tente ser mais breve.",
  badToken: () => "Este atalho não funciona mais. Crie um novo no Homebot.",
  forbiddenBot: () => "Este atalho não pode usar esse bot.",
  botNotConfigured: () => "O Homebot ainda não está configurado para este bot. Execute homebot doctor.",
  authFailed: () => "O Homebot não consegue entrar no Grok Bot. Verifique os ajustes.",
  upstreamDown: () => "Não é possível acessar o Grok Bot agora. Tente de novo mais tarde.",
  rateLimited: () => "Muitas perguntas seguidas. Aguarde um momento.",
  internalError: () => "O Homebot encontrou um erro. Tente de novo mais tarde.",
  more: () => "Mais alguma coisa?",
  goodbye: () => "Tá bom.",
  restart: () => "Vamos recomeçar: diga o nome do atalho de novo.",
};

const ru: Messages = {
  busy: (bot) => `${bot} сейчас занят. Спросите, пожалуйста, позже.`,
  inFlight: (bot) => `${bot} ещё отвечает на предыдущий вопрос.`,
  notSent: () => "Не удалось отправить вовремя. Спросите ещё раз.",
  noReplyInTime: (bot) => `${bot} не ответил вовремя. Возможно, вопрос уже доставлен: посмотрите переписку в Grok Bot, а не спрашивайте снова.`,
  refused: () => "Ответ пришёл, но Homebot не может подтвердить, что он на этот вопрос, поэтому не будет его читать. Посмотрите в Grok Bot.",
  unspeakable: () => "В ответе нет текста, который можно прочитать вслух. Посмотрите в Grok Bot.",
  wrongScript: () => "Ответ на языке, который голос этой быстрой команды не может прочитать. Посмотрите в Grok Bot.",
  emptyQuestion: () => "Не удалось расслышать. Повторите, пожалуйста.",
  tooLong: () => "Вопрос слишком длинный. Скажите короче.",
  badToken: () => "Эта команда больше не работает. Создайте новую в Homebot.",
  forbiddenBot: () => "Этой команде нельзя использовать этого бота.",
  botNotConfigured: () => "Homebot ещё не настроен для этого бота. Запустите homebot doctor.",
  authFailed: () => "Homebot не может войти в Grok Bot. Проверьте настройки.",
  upstreamDown: () => "Grok Bot сейчас недоступен. Попробуйте позже.",
  rateLimited: () => "Слишком много вопросов подряд. Подождите немного.",
  internalError: () => "В Homebot произошла ошибка. Попробуйте позже.",
  more: () => "Что-нибудь ещё?",
  goodbye: () => "Хорошо.",
  restart: () => "Давайте начнём сначала: ещё раз скажите название команды.",
};

const ja: Messages = {
  busy: (bot) => `${bot}は今ほかの作業中です。しばらくしてからもう一度聞いてください。`,
  inFlight: (bot) => `${bot}はまだ前の質問に答えています。`,
  notSent: () => "時間内に送信できませんでした。もう一度聞いてください。",
  noReplyInTime: (bot) => `${bot}から時間内に返事がありませんでした。質問は届いているかもしれません。もう一度聞かずに、Grok Botで会話を確認してください。`,
  refused: () => "返事は届きましたが、この質問への答えだと確認できないため読み上げません。Grok Botで確認してください。",
  unspeakable: () => "返事に読み上げられるテキストがありません。Grok Botで確認してください。",
  wrongScript: () => "返事は、このショートカットの音声では読めない言語です。Grok Botで確認してください。",
  emptyQuestion: () => "聞き取れませんでした。もう一度お願いします。",
  tooLong: () => "質問が長すぎます。短くしてください。",
  badToken: () => "このショートカットはもう使えません。Homebotで新しく作ってください。",
  forbiddenBot: () => "このショートカットはそのボットを使えません。",
  botNotConfigured: () => "このボットはまだHomebotに設定されていません。homebot doctorを実行してください。",
  authFailed: () => "HomebotがGrok Botにサインインできません。設定を確認してください。",
  upstreamDown: () => "今はGrok Botに接続できません。しばらくしてからもう一度お試しください。",
  rateLimited: () => "質問が続きすぎています。少し待ってください。",
  internalError: () => "Homebotでエラーが起きました。しばらくしてからもう一度お試しください。",
  more: () => "ほかにありますか？",
  goodbye: () => "わかりました。",
  restart: () => "最初からやり直しましょう。もう一度ショートカットの名前を言ってください。",
};

// Korean particles depend on the last syllable of the bot's name, which can be anything, so the
// name is followed only by particles that fit every noun (에서, 에게).
const ko: Messages = {
  busy: (bot) => `지금 ${bot}에서 다른 일을 하고 있습니다. 잠시 후 다시 물어보세요.`,
  inFlight: (bot) => `${bot}에서 아직 이전 질문에 답하고 있습니다.`,
  notSent: () => "제시간에 보내지 못했습니다. 다시 물어보세요.",
  noReplyInTime: (bot) => `${bot}에서 제시간에 답하지 않았습니다. 질문은 전달되었을 수 있으니, 다시 묻지 말고 Grok Bot에서 대화를 확인하세요.`,
  refused: () => "답이 왔지만 이 질문에 대한 답인지 Homebot이 확인할 수 없어서 읽어 드리지 않습니다. Grok Bot에서 확인하세요.",
  unspeakable: () => "답에 소리 내어 읽을 수 있는 텍스트가 없습니다. Grok Bot에서 확인하세요.",
  wrongScript: () => "답이 이 단축어 음성으로 읽을 수 없는 언어로 되어 있습니다. Grok Bot에서 확인하세요.",
  emptyQuestion: () => "잘 못 들었어요. 다시 말씀해 주세요.",
  tooLong: () => "질문이 너무 깁니다. 짧게 말씀해 주세요.",
  badToken: () => "이 단축어는 더 이상 작동하지 않습니다. Homebot에서 새로 만드세요.",
  forbiddenBot: () => "이 단축어는 그 봇을 사용할 수 없습니다.",
  botNotConfigured: () => "이 봇은 아직 Homebot에 설정되지 않았습니다. homebot doctor를 실행하세요.",
  authFailed: () => "Homebot이 Grok Bot에 로그인할 수 없습니다. 설정을 확인하세요.",
  upstreamDown: () => "지금은 Grok Bot에 연결할 수 없습니다. 잠시 후 다시 시도하세요.",
  rateLimited: () => "질문이 너무 잦습니다. 잠시 기다려 주세요.",
  internalError: () => "Homebot에 오류가 발생했습니다. 잠시 후 다시 시도하세요.",
  more: () => "더 필요한 게 있으세요?",
  goodbye: () => "알겠습니다.",
  restart: () => "처음부터 다시 할게요. 단축어 이름을 다시 말씀해 주세요.",
};

const zhTW: Messages = {
  busy: (bot) => `${bot}正在忙，請稍後再問。`,
  inFlight: (bot) => `${bot}還在回答上一個問題。`,
  notSent: () => "來不及送出，請再問一次。",
  noReplyInTime: (bot) => `${bot}沒有及時回覆。問題可能已經送達，請到 Grok Bot 查看，不要重複提問。`,
  refused: () => "收到了回覆，但無法確認它是在回答這個問題，所以沒有朗讀。請到 Grok Bot 查看。",
  unspeakable: () => "回覆裡沒有可以朗讀的文字，請到 Grok Bot 查看。",
  wrongScript: () => "這則回覆用的語言，這個捷徑的語音讀不了，請到 Grok Bot 查看。",
  emptyQuestion: () => "沒聽清楚，請再說一次。",
  tooLong: () => "問題太長了，請說得簡短一點。",
  badToken: () => "這個捷徑已經失效，請在 Homebot 裡重新製作。",
  forbiddenBot: () => "這個捷徑不能使用這個 bot。",
  botNotConfigured: () => "Homebot 還沒有設定好這個 bot，請執行 homebot doctor。",
  authFailed: () => "Homebot 無法登入 Grok Bot，請檢查設定。",
  upstreamDown: () => "暫時連不上 Grok Bot，請稍後再試。",
  rateLimited: () => "問得太頻繁了，請稍等一下。",
  internalError: () => "Homebot 發生錯誤，請稍後再試。",
  more: () => "還有嗎？",
  goodbye: () => "好的。",
  restart: () => "我們重新開始吧，請再說一次捷徑的名稱。",
};

const CATALOG: Record<Lang, Messages> = { en, es, fr, de, it, "pt-BR": ptBR, ru, ja, ko, "zh-CN": zh, "zh-TW": zhTW };

const isLang = (l: string): l is Lang => Object.hasOwn(CATALOG, l);

/** English is the default for unknown or missing languages. */
export const messages = (lang: string | undefined): Messages => (lang && isLang(lang) ? CATALOG[lang] : en);
// CATALOG is a Record<Lang, …> literal, so its own keys are exactly the Lang values.
export const LANGS = Object.keys(CATALOG) as Lang[];
