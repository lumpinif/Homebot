// GENERATED from the TypeScript catalogs (src/core/i18n.ts, envelope.ts, conversation.ts,
// src/shortcut/profile.ts, src/server/voice.ts) by scripts/swift-catalogs.ts. Do not edit by hand:
// change the TypeScript source while it is the reference, then regenerate. GoldenTests compares
// every entry with a dump of the TypeScript output.
// swiftlint:disable all
import Foundation

extension Messages {
  static let catalog: [ReplyLang: Messages] = [
    .en: Messages(
      busy: { bot in "\(bot) is busy. Please ask again later." },
      inFlight: { bot in "\(bot) is still answering the previous question." },
      notSent: "That didn't get sent in time. Please ask again.",
      noReplyInTime: { bot in "\(bot) didn't reply in time. Your question may have been delivered; check the conversation in Grok Bot instead of asking again." },
      refused: "A reply arrived, but Homebot can't confirm it answers this question, so it won't be read aloud. Please check Grok Bot.",
      unspeakable: "The reply has no text that can be read aloud. Please check Grok Bot.",
      emptyQuestion: "I didn't catch that. Please say it again.",
      tooLong: "That question is too long. Please keep it short.",
      badToken: "This shortcut no longer works. Please make a new one in Homebot.",
      forbiddenBot: "This shortcut isn't allowed to use that bot.",
      botNotConfigured: "Homebot isn't set up for this bot yet. Run homebot doctor.",
      authFailed: "Homebot can't sign in to Grok Bot. Please check the settings.",
      upstreamDown: "Grok Bot can't be reached right now. Please try again later.",
      rateLimited: "Too many questions in a row. Please wait a moment.",
      internalError: "Homebot ran into an error. Please try again later.",
      more: "Anything else?",
      goodbye: "Okay.",
      restart: "Let's start again: say the Shortcut's name again."
    ),
    .es: Messages(
      busy: { bot in "\(bot) está ocupado. Vuelve a preguntar más tarde." },
      inFlight: { bot in "\(bot) todavía está respondiendo a la pregunta anterior." },
      notSent: "No se ha podido enviar a tiempo. Vuelve a preguntar.",
      noReplyInTime: { bot in "\(bot) no ha respondido a tiempo. Puede que la pregunta haya llegado; mira la conversación en Grok Bot en vez de volver a preguntar." },
      refused: "Ha llegado una respuesta, pero Homebot no puede confirmar que sea de esta pregunta, así que no la leerá. Míralo en Grok Bot.",
      unspeakable: "La respuesta no tiene texto que se pueda leer en voz alta. Míralo en Grok Bot.",
      emptyQuestion: "No te he entendido. Repítelo, por favor.",
      tooLong: "La pregunta es demasiado larga. Hazla más corta.",
      badToken: "Este atajo ya no funciona. Crea uno nuevo en Homebot.",
      forbiddenBot: "Este atajo no puede usar ese bot.",
      botNotConfigured: "Homebot aún no está configurado para este bot. Ejecuta homebot doctor.",
      authFailed: "Homebot no puede iniciar sesión en Grok Bot. Revisa los ajustes.",
      upstreamDown: "Ahora mismo no se puede conectar con Grok Bot. Inténtalo más tarde.",
      rateLimited: "Demasiadas preguntas seguidas. Espera un momento.",
      internalError: "Homebot ha tenido un error. Inténtalo más tarde.",
      more: "¿Algo más?",
      goodbye: "Vale.",
      restart: "Empecemos de nuevo: vuelve a decir el nombre del atajo."
    ),
    .fr: Messages(
      busy: { bot in "\(bot) est occupé. Reposez la question plus tard." },
      inFlight: { bot in "\(bot) répond encore à la question précédente." },
      notSent: "La question n’a pas pu être envoyée à temps. Reposez-la.",
      noReplyInTime: { bot in "\(bot) n’a pas répondu à temps. Votre question est peut-être arrivée : regardez la conversation dans Grok Bot plutôt que de la reposer." },
      refused: "Une réponse est arrivée, mais Homebot ne peut pas confirmer qu’elle répond à cette question, donc elle ne sera pas lue. Regardez dans Grok Bot.",
      unspeakable: "La réponse ne contient aucun texte à lire à voix haute. Regardez dans Grok Bot.",
      emptyQuestion: "Je n’ai pas compris. Pouvez-vous répéter ?",
      tooLong: "La question est trop longue. Faites plus court.",
      badToken: "Ce raccourci ne fonctionne plus. Créez-en un nouveau dans Homebot.",
      forbiddenBot: "Ce raccourci n’a pas le droit d’utiliser ce bot.",
      botNotConfigured: "Homebot n’est pas encore configuré pour ce bot. Lancez homebot doctor.",
      authFailed: "Homebot n’arrive pas à se connecter à Grok Bot. Vérifiez les réglages.",
      upstreamDown: "Grok Bot est injoignable pour le moment. Réessayez plus tard.",
      rateLimited: "Trop de questions d’affilée. Patientez un instant.",
      internalError: "Homebot a rencontré une erreur. Réessayez plus tard.",
      more: "Autre chose ?",
      goodbye: "D’accord.",
      restart: "Recommençons : redites le nom du raccourci."
    ),
    .de: Messages(
      busy: { bot in "\(bot) ist gerade beschäftigt. Frag bitte später noch einmal." },
      inFlight: { bot in "\(bot) beantwortet noch die vorherige Frage." },
      notSent: "Das konnte nicht rechtzeitig gesendet werden. Frag bitte noch einmal.",
      noReplyInTime: { bot in "\(bot) hat nicht rechtzeitig geantwortet. Deine Frage ist vielleicht angekommen. Sieh in Grok Bot nach, statt noch einmal zu fragen." },
      refused: "Eine Antwort ist da, aber Homebot kann nicht bestätigen, dass sie zu dieser Frage gehört. Deshalb wird sie nicht vorgelesen. Sieh bitte in Grok Bot nach.",
      unspeakable: "Die Antwort enthält keinen Text zum Vorlesen. Sieh bitte in Grok Bot nach.",
      emptyQuestion: "Das habe ich nicht verstanden. Sag es bitte noch einmal.",
      tooLong: "Die Frage ist zu lang. Bitte fass dich kürzer.",
      badToken: "Dieser Kurzbefehl funktioniert nicht mehr. Erstelle in Homebot einen neuen.",
      forbiddenBot: "Dieser Kurzbefehl darf diesen Bot nicht verwenden.",
      botNotConfigured: "Homebot ist für diesen Bot noch nicht eingerichtet. Führe homebot doctor aus.",
      authFailed: "Homebot kann sich nicht bei Grok Bot anmelden. Prüf bitte die Einstellungen.",
      upstreamDown: "Grok Bot ist gerade nicht erreichbar. Versuch es später noch einmal.",
      rateLimited: "Zu viele Fragen hintereinander. Warte bitte einen Moment.",
      internalError: "In Homebot ist ein Fehler aufgetreten. Versuch es später noch einmal.",
      more: "Sonst noch etwas?",
      goodbye: "Okay.",
      restart: "Fangen wir neu an: Sag noch einmal den Namen des Kurzbefehls."
    ),
    .it: Messages(
      busy: { bot in "\(bot) è occupato. Riprova più tardi." },
      inFlight: { bot in "\(bot) sta ancora rispondendo alla domanda precedente." },
      notSent: "Non è stato possibile inviarla in tempo. Riprova a chiedere.",
      noReplyInTime: { bot in "\(bot) non ha risposto in tempo. La domanda potrebbe essere arrivata: controlla la conversazione in Grok Bot invece di chiedere di nuovo." },
      refused: "È arrivata una risposta, ma Homebot non può confermare che sia per questa domanda, quindi non la leggerà. Controlla in Grok Bot.",
      unspeakable: "La risposta non contiene testo da leggere ad alta voce. Controlla in Grok Bot.",
      emptyQuestion: "Non ho capito. Puoi ripetere?",
      tooLong: "La domanda è troppo lunga. Prova a essere più breve.",
      badToken: "Questo comando rapido non funziona più. Creane uno nuovo in Homebot.",
      forbiddenBot: "Questo comando rapido non può usare quel bot.",
      botNotConfigured: "Homebot non è ancora configurato per questo bot. Esegui homebot doctor.",
      authFailed: "Homebot non riesce ad accedere a Grok Bot. Controlla le impostazioni.",
      upstreamDown: "Al momento Grok Bot non è raggiungibile. Riprova più tardi.",
      rateLimited: "Troppe domande di fila. Aspetta un momento.",
      internalError: "Si è verificato un errore in Homebot. Riprova più tardi.",
      more: "Altro?",
      goodbye: "Va bene.",
      restart: "Ricominciamo: ripeti il nome del comando rapido."
    ),
    .ptBR: Messages(
      busy: { bot in "\(bot) está ocupado. Pergunte de novo mais tarde." },
      inFlight: { bot in "\(bot) ainda está respondendo à pergunta anterior." },
      notSent: "Não deu tempo de enviar. Pergunte de novo.",
      noReplyInTime: { bot in "\(bot) não respondeu a tempo. Sua pergunta pode ter chegado; confira a conversa no Grok Bot em vez de perguntar de novo." },
      refused: "Chegou uma resposta, mas o Homebot não consegue confirmar que ela é desta pergunta, então ela não será lida. Confira no Grok Bot.",
      unspeakable: "A resposta não tem texto que possa ser lido em voz alta. Confira no Grok Bot.",
      emptyQuestion: "Não entendi. Pode repetir?",
      tooLong: "A pergunta está longa demais. Tente ser mais breve.",
      badToken: "Este atalho não funciona mais. Crie um novo no Homebot.",
      forbiddenBot: "Este atalho não pode usar esse bot.",
      botNotConfigured: "O Homebot ainda não está configurado para este bot. Execute homebot doctor.",
      authFailed: "O Homebot não consegue entrar no Grok Bot. Verifique os ajustes.",
      upstreamDown: "Não é possível acessar o Grok Bot agora. Tente de novo mais tarde.",
      rateLimited: "Muitas perguntas seguidas. Aguarde um momento.",
      internalError: "O Homebot encontrou um erro. Tente de novo mais tarde.",
      more: "Mais alguma coisa?",
      goodbye: "Tá bom.",
      restart: "Vamos recomeçar: diga o nome do atalho de novo."
    ),
    .ru: Messages(
      busy: { bot in "\(bot) сейчас занят. Спросите, пожалуйста, позже." },
      inFlight: { bot in "\(bot) ещё отвечает на предыдущий вопрос." },
      notSent: "Не удалось отправить вовремя. Спросите ещё раз.",
      noReplyInTime: { bot in "\(bot) не ответил вовремя. Возможно, вопрос уже доставлен: посмотрите переписку в Grok Bot, а не спрашивайте снова." },
      refused: "Ответ пришёл, но Homebot не может подтвердить, что он на этот вопрос, поэтому не будет его читать. Посмотрите в Grok Bot.",
      unspeakable: "В ответе нет текста, который можно прочитать вслух. Посмотрите в Grok Bot.",
      emptyQuestion: "Не удалось расслышать. Повторите, пожалуйста.",
      tooLong: "Вопрос слишком длинный. Скажите короче.",
      badToken: "Эта команда больше не работает. Создайте новую в Homebot.",
      forbiddenBot: "Этой команде нельзя использовать этого бота.",
      botNotConfigured: "Homebot ещё не настроен для этого бота. Запустите homebot doctor.",
      authFailed: "Homebot не может войти в Grok Bot. Проверьте настройки.",
      upstreamDown: "Grok Bot сейчас недоступен. Попробуйте позже.",
      rateLimited: "Слишком много вопросов подряд. Подождите немного.",
      internalError: "В Homebot произошла ошибка. Попробуйте позже.",
      more: "Что-нибудь ещё?",
      goodbye: "Хорошо.",
      restart: "Давайте начнём сначала: ещё раз скажите название команды."
    ),
    .ja: Messages(
      busy: { bot in "\(bot)は今ほかの作業中です。しばらくしてからもう一度聞いてください。" },
      inFlight: { bot in "\(bot)はまだ前の質問に答えています。" },
      notSent: "時間内に送信できませんでした。もう一度聞いてください。",
      noReplyInTime: { bot in "\(bot)から時間内に返事がありませんでした。質問は届いているかもしれません。もう一度聞かずに、Grok Botで会話を確認してください。" },
      refused: "返事は届きましたが、この質問への答えだと確認できないため読み上げません。Grok Botで確認してください。",
      unspeakable: "返事に読み上げられるテキストがありません。Grok Botで確認してください。",
      emptyQuestion: "聞き取れませんでした。もう一度お願いします。",
      tooLong: "質問が長すぎます。短くしてください。",
      badToken: "このショートカットはもう使えません。Homebotで新しく作ってください。",
      forbiddenBot: "このショートカットはそのボットを使えません。",
      botNotConfigured: "このボットはまだHomebotに設定されていません。homebot doctorを実行してください。",
      authFailed: "HomebotがGrok Botにサインインできません。設定を確認してください。",
      upstreamDown: "今はGrok Botに接続できません。しばらくしてからもう一度お試しください。",
      rateLimited: "質問が続きすぎています。少し待ってください。",
      internalError: "Homebotでエラーが起きました。しばらくしてからもう一度お試しください。",
      more: "ほかにありますか？",
      goodbye: "わかりました。",
      restart: "最初からやり直しましょう。もう一度ショートカットの名前を言ってください。"
    ),
    .ko: Messages(
      busy: { bot in "지금 \(bot)에서 다른 일을 하고 있습니다. 잠시 후 다시 물어보세요." },
      inFlight: { bot in "\(bot)에서 아직 이전 질문에 답하고 있습니다." },
      notSent: "제시간에 보내지 못했습니다. 다시 물어보세요.",
      noReplyInTime: { bot in "\(bot)에서 제시간에 답하지 않았습니다. 질문은 전달되었을 수 있으니, 다시 묻지 말고 Grok Bot에서 대화를 확인하세요." },
      refused: "답이 왔지만 이 질문에 대한 답인지 Homebot이 확인할 수 없어서 읽어 드리지 않습니다. Grok Bot에서 확인하세요.",
      unspeakable: "답에 소리 내어 읽을 수 있는 텍스트가 없습니다. Grok Bot에서 확인하세요.",
      emptyQuestion: "잘 못 들었어요. 다시 말씀해 주세요.",
      tooLong: "질문이 너무 깁니다. 짧게 말씀해 주세요.",
      badToken: "이 단축어는 더 이상 작동하지 않습니다. Homebot에서 새로 만드세요.",
      forbiddenBot: "이 단축어는 그 봇을 사용할 수 없습니다.",
      botNotConfigured: "이 봇은 아직 Homebot에 설정되지 않았습니다. homebot doctor를 실행하세요.",
      authFailed: "Homebot이 Grok Bot에 로그인할 수 없습니다. 설정을 확인하세요.",
      upstreamDown: "지금은 Grok Bot에 연결할 수 없습니다. 잠시 후 다시 시도하세요.",
      rateLimited: "질문이 너무 잦습니다. 잠시 기다려 주세요.",
      internalError: "Homebot에 오류가 발생했습니다. 잠시 후 다시 시도하세요.",
      more: "더 필요한 게 있으세요?",
      goodbye: "알겠습니다.",
      restart: "처음부터 다시 할게요. 단축어 이름을 다시 말씀해 주세요."
    ),
    .zhCN: Messages(
      busy: { bot in "\(bot)正在忙，请稍后再问。" },
      inFlight: { bot in "\(bot)还在回答上一个问题。" },
      notSent: "没来得及发送，请再问一次。",
      noReplyInTime: { bot in "\(bot)没有及时回复。问题可能已经送达，请在 Grok Bot 里查看，不要重复提问。" },
      refused: "收到了回复，但无法确认它是在回答这个问题，所以没有朗读。请在 Grok Bot 里查看。",
      unspeakable: "回复里没有可以朗读的文字，请在 Grok Bot 里查看。",
      emptyQuestion: "没听清，请再说一次。",
      tooLong: "问题太长了，请说得简短一些。",
      badToken: "这个快捷指令已失效，请在 Homebot 里重新生成。",
      forbiddenBot: "这个快捷指令不能使用这个 bot。",
      botNotConfigured: "Homebot 还没有配置好这个 bot，请运行 homebot doctor。",
      authFailed: "Homebot 无法登录 Grok Bot，请检查设置。",
      upstreamDown: "Grok Bot 暂时连不上，请稍后再试。",
      rateLimited: "问得太频繁了，请稍等一下。",
      internalError: "Homebot 出错了，请稍后再试。",
      more: "还有吗？",
      goodbye: "好的。",
      restart: "我们重新开始吧，请再说一次快捷指令的名字。"
    ),
    .zhTW: Messages(
      busy: { bot in "\(bot)正在忙，請稍後再問。" },
      inFlight: { bot in "\(bot)還在回答上一個問題。" },
      notSent: "來不及送出，請再問一次。",
      noReplyInTime: { bot in "\(bot)沒有及時回覆。問題可能已經送達，請到 Grok Bot 查看，不要重複提問。" },
      refused: "收到了回覆，但無法確認它是在回答這個問題，所以沒有朗讀。請到 Grok Bot 查看。",
      unspeakable: "回覆裡沒有可以朗讀的文字，請到 Grok Bot 查看。",
      emptyQuestion: "沒聽清楚，請再說一次。",
      tooLong: "問題太長了，請說得簡短一點。",
      badToken: "這個捷徑已經失效，請在 Homebot 裡重新製作。",
      forbiddenBot: "這個捷徑不能使用這個 bot。",
      botNotConfigured: "Homebot 還沒有設定好這個 bot，請執行 homebot doctor。",
      authFailed: "Homebot 無法登入 Grok Bot，請檢查設定。",
      upstreamDown: "暫時連不上 Grok Bot，請稍後再試。",
      rateLimited: "問得太頻繁了，請稍等一下。",
      internalError: "Homebot 發生錯誤，請稍後再試。",
      more: "還有嗎？",
      goodbye: "好的。",
      restart: "我們重新開始吧，請再說一次捷徑的名稱。"
    ),
  ]
}

extension Envelope {
  static let styles: [ReplyLang: Style] = [
    .en: Style(
      intro: "(Homebot: this was spoken to Siri on a HomePod/iPhone; your reply is read aloud in the room.",
      turn: { n in "This is turn \(n) of a voice conversation; the user can reply right away. End with a statement unless a question is needed. The room hears only your first message for this turn." },
      echo: { tag in "Start your reply with \(tag)." },
      style: "Then answer in English, in 1-3 short spoken sentences, at most about 50 words. An English voice reads it aloud, so answer in English even if the question is in another language. No markdown, links, lists, code or emoji.)"
    ),
    .es: Style(
      intro: "(Homebot: esto se le dijo a Siri en un HomePod o iPhone; tu respuesta se leerá en voz alta en la habitación.",
      turn: { n in "Este es el turno \(n) de una conversación por voz; el usuario puede responder enseguida. Termina con una afirmación salvo que haga falta una pregunta. En la habitación solo se oye tu primer mensaje de este turno." },
      echo: { tag in "Empieza tu respuesta con \(tag)." },
      style: "Después responde en español, en 1 a 3 frases breves y habladas, como mucho unas 50 palabras. Una voz en español lo lee en voz alta, así que responde en español aunque la pregunta esté en otro idioma. Sin markdown, enlaces, listas, código ni emojis.)"
    ),
    .fr: Style(
      intro: "(Homebot : ceci a été dit à Siri sur un HomePod ou un iPhone ; ta réponse sera lue à voix haute dans la pièce.",
      turn: { n in "C’est le tour \(n) d’une conversation vocale ; l’utilisateur peut répondre tout de suite. Termine par une affirmation sauf si une question est nécessaire. La pièce n’entend que ton premier message de ce tour." },
      echo: { tag in "Commence ta réponse par \(tag)." },
      style: "Ensuite, réponds en français, en 1 à 3 phrases courtes et parlées, environ 50 mots au plus. Une voix française la lit à voix haute, donc réponds en français même si la question est dans une autre langue. Pas de markdown, de liens, de listes, de code ni d’emoji.)"
    ),
    .de: Style(
      intro: "(Homebot: Das wurde zu Siri auf einem HomePod oder iPhone gesagt; deine Antwort wird im Raum vorgelesen.",
      turn: { n in "Das ist Runde \(n) eines Sprachgesprächs; der Nutzer kann sofort antworten. Ende mit einer Aussage, außer eine Frage ist nötig. Im Raum ist nur deine erste Nachricht dieser Runde zu hören." },
      echo: { tag in "Beginne deine Antwort mit \(tag)." },
      style: "Antworte dann auf Deutsch, in 1 bis 3 kurzen, gesprochenen Sätzen, höchstens etwa 50 Wörter. Eine deutsche Stimme liest sie vor, also antworte auf Deutsch, auch wenn die Frage in einer anderen Sprache ist. Kein Markdown, keine Links, Listen, Code oder Emojis.)"
    ),
    .it: Style(
      intro: "(Homebot: questo è stato detto a Siri su un HomePod o un iPhone; la tua risposta verrà letta ad alta voce nella stanza.",
      turn: { n in "Questo è il turno \(n) di una conversazione vocale; l’utente può rispondere subito. Chiudi con un’affermazione, a meno che non serva una domanda. Nella stanza si sente solo il tuo primo messaggio di questo turno." },
      echo: { tag in "Inizia la risposta con \(tag)." },
      style: "Poi rispondi in italiano, con 1-3 frasi brevi e parlate, al massimo circa 50 parole. Una voce italiana la legge ad alta voce, quindi rispondi in italiano anche se la domanda è in un’altra lingua. Niente markdown, link, elenchi, codice o emoji.)"
    ),
    .ptBR: Style(
      intro: "(Homebot: isto foi dito à Siri em um HomePod ou iPhone; sua resposta será lida em voz alta no ambiente.",
      turn: { n in "Esta é a rodada \(n) de uma conversa por voz; o usuário pode responder logo em seguida. Termine com uma afirmação, a menos que uma pergunta seja necessária. No ambiente só se ouve a sua primeira mensagem desta rodada." },
      echo: { tag in "Comece sua resposta com \(tag)." },
      style: "Depois responda em português do Brasil, em 1 a 3 frases curtas e faladas, no máximo umas 50 palavras. Uma voz em português lê a resposta em voz alta, então responda em português mesmo que a pergunta esteja em outro idioma. Sem markdown, links, listas, código ou emoji.)"
    ),
    .ru: Style(
      intro: "(Homebot: это было сказано Siri на HomePod или iPhone; твой ответ прочитают вслух в комнате.",
      turn: { n in "Это ход \(n) голосового разговора; пользователь может сразу ответить. Заканчивай утверждением, если вопрос не нужен. В комнате слышно только твоё первое сообщение в этом ходе." },
      echo: { tag in "Начни ответ с \(tag)." },
      style: "Затем ответь по-русски, 1–3 короткими разговорными предложениями, не больше примерно 50 слов. Ответ читает вслух русский голос, поэтому отвечай по-русски, даже если вопрос задан на другом языке. Без markdown, ссылок, списков, кода и эмодзи.)"
    ),
    .ja: Style(
      intro: "（Homebot：これは HomePod または iPhone の Siri に話しかけた内容です。あなたの返事は部屋で読み上げられます。",
      turn: { n in "これは音声での会話の\(n)回目です。ユーザーはすぐに返事ができます。質問が必要な場合を除き、文で締めくくってください。部屋で聞こえるのは、この回のあなたの最初のメッセージだけです。" },
      echo: { tag in "返事は \(tag) で始めてください。" },
      style: "続けて、日本語の話し言葉の短い文1〜3つ、全部で80文字以内で答えてください。日本語の音声で読み上げるので、質問が別の言語でも日本語で答えてください。Markdown、リンク、箇条書き、コード、絵文字は使わないでください。）"
    ),
    .ko: Style(
      intro: "(Homebot: HomePod 또는 iPhone의 Siri에게 한 말입니다. 답은 방에서 소리 내어 읽힙니다.",
      turn: { n in "음성 대화의 \(n)번째 차례입니다. 사용자는 바로 이어서 말할 수 있습니다. 꼭 필요한 경우가 아니면 질문으로 끝내지 마세요. 방에서는 이번 차례의 첫 메시지만 들립니다." },
      echo: { tag in "답의 맨 앞에 \(tag) 표시를 그대로 쓰세요." },
      style: "그다음 한국어로, 짧은 구어체 문장 1~3개, 모두 합쳐 약 120자 이내로 답하세요. 한국어 음성이 소리 내어 읽으므로 질문이 다른 언어여도 한국어로 답하세요. 마크다운, 링크, 목록, 코드, 이모지는 쓰지 마세요.)"
    ),
    .zhCN: Style(
      intro: "（Homebot：这是对 HomePod/iPhone 上的 Siri 说的话，你的回复会在房间里被朗读出来。",
      turn: { n in "这是语音对话的第 \(n) 轮，用户听完可以马上接着说；除非必要，不要以问题结尾；房间里只会听到你这一轮的第一条消息。" },
      echo: { tag in "回复请以 \(tag) 开头。" },
      style: "然后用中文回答，1 到 3 句简短口语，总共不超过 80 个字；回复由中文语音朗读，所以即使提问用的是别的语言，也要用中文回答。不要 markdown、链接、列表、代码或表情。）"
    ),
    .zhTW: Style(
      intro: "（Homebot：這是對 HomePod/iPhone 上的 Siri 說的話，你的回覆會在房間裡被朗讀出來。",
      turn: { n in "這是語音對話的第 \(n) 輪，使用者聽完可以馬上接著說；除非必要，不要以問題結尾；房間裡只會聽到你這一輪的第一則訊息。" },
      echo: { tag in "回覆請以 \(tag) 開頭。" },
      style: "然後用繁體中文（台灣用語）回答，1 到 3 句簡短口語，總共不超過 80 個字；回覆由中文語音朗讀，所以即使提問用的是別的語言，也要用繁體中文回答。不要 markdown、連結、清單、程式碼或表情符號。）"
    ),
  ]
}

extension Conversation {
  static let endWords: [ReplyLang: [String]] = [
    .en: ["stop", "goodbye", "thats all", "thanks", "never mind"],
    .es: ["para", "basta", "adiós", "eso es todo", "gracias", "nada más", "déjalo"],
    .fr: ["stop", "au revoir", "cest tout", "merci", "laisse tomber", "rien"],
    .de: ["stopp", "schluss", "tschüss", "das wars", "danke", "schon gut", "nichts mehr"],
    .it: ["basta", "stop", "ciao", "arrivederci", "è tutto", "grazie", "non importa", "lascia stare"],
    .ptBR: ["parar", "chega", "tchau", "é só isso", "era só isso", "obrigado", "obrigada", "deixa pra lá"],
    .ru: ["стоп", "хватит", "пока", "это всё", "это все", "спасибо", "ничего", "не надо"],
    .ja: ["終わり", "終了", "やめて", "さようなら", "ありがとう", "バイバイ", "もういい"],
    .ko: ["그만", "종료", "끝", "안녕", "고마워", "감사합니다", "됐어"],
    .zhCN: ["结束", "退出", "再见", "谢谢", "没事了", "不用了"],
    .zhTW: ["結束", "退出", "再見", "謝謝", "沒事了", "不用了"],
  ]
}

extension Catalogs {
  static let probeTextTemplates: [ReplyLang: @Sendable (Int) -> String] = [
    .en: { n in "Waited \(n) seconds." },
    .es: { n in "He esperado \(n) segundos." },
    .fr: { n in "J’ai attendu \(n) secondes." },
    .de: { n in "\(n) Sekunden gewartet." },
    .it: { n in "Ho aspettato \(n) secondi." },
    .ptBR: { n in "Esperei \(n) segundos." },
    .ja: { n in "\(n)秒待ちました。" },
    .ko: { n in "\(n)초 기다렸습니다." },
    .zhCN: { n in "等了\(n)秒，收到。" },
    .zhTW: { n in "等了\(n)秒，收到。" },
  ]
}

extension PhraseRow {
  static let rows: [ReplyLang: PhraseRow] = [
    .en: PhraseRow(
      script: "^[A-Za-z]+(?:[ '-][A-Za-z]+)*$",
      spaced: true,
      products: ["Grok Bot", "My Grok Bot", "Our Grok Bot"],
      badStarts: [.init("ask"), .init("call"), .init("play"), .init("set"), .init("open"), .init("turn"), .init("text"), .init("what"), .init("tell"), .init("search")],
      promptWithBot: { bot in "What would you like to ask \(bot)?" },
      promptWithoutBot: "What would you like to ask?",
      probeName: "Homebot Wait Test",
      labName: "Homebot Lab"
    ),
    .es: PhraseRow(
      script: "^\\p{Script=Latin}+(?:[ '’-]\\p{Script=Latin}+)*$",
      spaced: true,
      products: ["mayordomo", "ama de llaves", "asistente del hogar"],
      badStarts: [.init("pregunta"), .init("pregúntale"), .init("llama"), .init("pon"), .init("reproduce"), .init("abre"), .init("busca"), .init("envía"), .init("qué"), .init("activa"), .init("enciende"), .init("apaga"), .init("dime")],
      promptWithBot: { bot in "¿Qué quieres preguntarle a \(bot)?" },
      promptWithoutBot: "¿Qué quieres preguntar?",
      probeName: "prueba de espera",
      labName: "Homebot Lab"
    ),
    .fr: PhraseRow(
      script: "^\\p{Script=Latin}+(?:[ '’-]\\p{Script=Latin}+)*$",
      spaced: true,
      products: ["majordome", "intendant", "assistant du foyer"],
      badStarts: [.init("demande"), .init("appelle"), .init("joue"), .init("mets"), .init("ouvre"), .init("cherche"), .init("envoie"), .init("quel"), .init("quelle"), .init("allume"), .init("éteins")],
      promptWithBot: { bot in "Que voulez-vous demander à \(bot) ?" },
      promptWithoutBot: "Que voulez-vous demander ?",
      probeName: "test d'attente",
      labName: "Homebot Lab"
    ),
    .de: PhraseRow(
      script: "^\\p{Script=Latin}+(?:[ '’-]\\p{Script=Latin}+)*$",
      spaced: true,
      products: ["Hausgeist", "Haushelfer", "Hausdiener"],
      badStarts: [.init("frag"), .init("frage"), .init("ruf"), .init("spiel"), .init("öffne"), .init("such"), .init("suche"), .init("schick"), .init("was"), .init("schalte"), .init("stell")],
      promptWithBot: { bot in "Was möchtest du \(bot) fragen?" },
      promptWithoutBot: "Was möchtest du fragen?",
      probeName: "Wartetest",
      labName: "Homebot Lab"
    ),
    .it: PhraseRow(
      script: "^\\p{Script=Latin}+(?:[ '’-]\\p{Script=Latin}+)*$",
      spaced: true,
      products: ["maggiordomo", "factotum", "aiutante di casa"],
      badStarts: [.init("chiedi"), .init("chiama"), .init("riproduci"), .init("metti"), .init("apri"), .init("cerca"), .init("invia"), .init("che"), .init("cosa"), .init("accendi"), .init("spegni"), .init("imposta"), .init("dimmi")],
      promptWithBot: { bot in "Cosa vuoi chiedere a \(bot)?" },
      promptWithoutBot: "Cosa vuoi chiedere?",
      probeName: "prova di attesa",
      labName: "Homebot Lab"
    ),
    .ptBR: PhraseRow(
      script: "^\\p{Script=Latin}+(?:[ '’-]\\p{Script=Latin}+)*$",
      spaced: true,
      products: ["mordomo", "assistente do lar", "ajudante do lar"],
      badStarts: [.init("pergunte"), .init("ligue"), .init("toque"), .init("abra"), .init("procure"), .init("busque"), .init("envie"), .init("mande"), .init("qual"), .init("o que"), .init("desligue"), .init("defina"), .init("diga")],
      promptWithBot: { bot in "O que você quer perguntar para \(bot)?" },
      promptWithoutBot: "O que você quer perguntar?",
      probeName: "teste de espera",
      labName: "Homebot Lab"
    ),
    .ru: PhraseRow(
      script: "^\\p{Script=Cyrillic}+(?:[ -]\\p{Script=Cyrillic}+)*$",
      spaced: true,
      products: ["домовой", "дворецкий", "домашний помощник"],
      badStarts: [.init("спроси"), .init("позвони"), .init("включи"), .init("выключи"), .init("открой"), .init("найди"), .init("отправь"), .init("напиши"), .init("что"), .init("поставь"), .init("скажи")],
      promptWithBot: { bot in "\(bot) слушает. Что вы хотите спросить?" },
      promptWithoutBot: "Что вы хотите спросить?",
      probeName: "проверка ожидания",
      labName: "домашняя лаборатория"
    ),
    .ja: PhraseRow(
      script: "^[\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Han}ー]+$",
      spaced: false,
      products: ["うち助手", "家事助手", "わが家の執事"],
      badStarts: [.init("聞いて"), .init("電話"), .init("再生"), .init("開いて"), .init("検索"), .init("送って"), .init("何"), .init("つけて"), .init("消して"), .init("教えて"), .init("設定")],
      promptWithBot: { bot in "\(bot)に何を聞きますか？" },
      promptWithoutBot: "何を聞きますか？",
      probeName: "待ち時間テスト",
      labName: "うち実験"
    ),
    .ko: PhraseRow(
      script: "^\\p{Script=Hangul}+(?: \\p{Script=Hangul}+)*$",
      spaced: true,
      products: ["집비서", "집도우미", "우리집 비서"],
      badStarts: [.init("물어봐"), .init("전화"), .init("재생"), .init("열어"), .init("검색"), .init("보내"), .init("뭐"), .init("켜"), .init("꺼"), .init("틀어"), .init("찾아"), .init("문자"), .init("설정")],
      promptWithBot: { bot in "\(bot)에게 무엇을 물어볼까요?" },
      promptWithoutBot: "무엇을 물어볼까요?",
      probeName: "대기 테스트",
      labName: "집 실험"
    ),
    .zhCN: PhraseRow(
      script: "^\\p{Script=Han}+$",
      spaced: false,
      products: ["家庭助手", "我家助手", "居家助手"],
      badStarts: [.init("问", strong: true), .init("查"), .init("播放"), .init("打开"), .init("设置"), .init("什么"), .init("呼叫"), .init("打电话")],
      promptWithBot: { bot in "想问\(bot)什么？" },
      promptWithoutBot: "想问什么？",
      probeName: "家庭等待测试",
      labName: "家庭实验"
    ),
    .zhTW: PhraseRow(
      script: "^\\p{Script=Han}+$",
      spaced: false,
      products: ["居家助理", "家裡助理", "我家助理"],
      badStarts: [.init("問", strong: true), .init("查"), .init("播放"), .init("打開"), .init("設定"), .init("什麼"), .init("打電話"), .init("撥打"), .init("呼叫"), .init("傳訊息")],
      promptWithBot: { bot in "想問\(bot)什麼？" },
      promptWithoutBot: "想問什麼？",
      probeName: "居家等待測試",
      labName: "居家實驗"
    ),
  ]
}

extension Profile {
  static let phoneSteps: [Lang: @Sendable (_ name: String, _ host: String) -> [String]] = [
    .en: { name, host in [
      "Send the file to your iPhone (AirDrop) and tap \"Add Shortcut\".",
      "In the Shortcuts app, run \"\(name)\" once by tapping it, and allow it to connect to \(host).",
      "Open the shortcut's details (ⓘ) and turn on \"Allow Running When Locked\" if you see it.",
      "For HomePod: in the Home app, turn on Recognize My Voice and Personal Content (Personal Requests before iOS 26), and make this iPhone your location device in Find My.",
      "Test on the iPhone first, with its Siri set to the same language as the HomePod's: \"Hey Siri, \(name)\". A new name can take minutes to a day to work on HomePod.",
    ] },
    .es: { name, host in [
      "Envía el archivo a tu iPhone (AirDrop) y toca «Añadir atajo».",
      "En la app Atajos, ejecuta «\(name)» una vez tocándolo y permite que se conecte a \(host).",
      "Abre los detalles del atajo (ⓘ) y activa «Permitir ejecución con el dispositivo bloqueado» si lo ves.",
      "Para el HomePod: en la app Casa, activa «Reconocer mi voz» y «Contenido personal», y establece este iPhone como dispositivo de ubicación en Buscar.",
      "Prueba primero en el iPhone, con Siri en el mismo idioma que el HomePod: «Oye Siri, \(name)». Un nombre nuevo puede tardar desde unos minutos hasta un día en funcionar en el HomePod.",
    ] },
    .fr: { name, host in [
      "Envoyez le fichier sur votre iPhone (AirDrop) et touchez « Ajouter ce raccourci ».",
      "Dans l’app Raccourcis, exécutez « \(name) » une fois en le touchant, et autorisez-le à se connecter à \(host).",
      "Ouvrez les détails du raccourci (ⓘ) et activez « Autoriser l’exécution en mode verrouillé » si vous le voyez.",
      "Pour le HomePod : dans l’app Maison, activez « Reconnaître ma voix » et « Contenu personnel », et faites de cet iPhone l’appareil de localisation dans Localiser.",
      "Testez d’abord sur l’iPhone, avec Siri dans la même langue que le HomePod : « Dis Siri, \(name) ». Un nouveau nom peut mettre de quelques minutes à un jour à fonctionner sur le HomePod.",
    ] },
    .de: { name, host in [
      "Sende die Datei an dein iPhone (AirDrop) und tippe auf „Kurzbefehl hinzufügen“.",
      "Führe in der Kurzbefehle-App „\(name)“ einmal aus, indem du darauf tippst, und erlaube die Verbindung mit \(host).",
      "Öffne die Details des Kurzbefehls (ⓘ) und aktiviere „Ausführung im Sperrzustand erlauben“, falls du es siehst.",
      "Für den HomePod: Aktiviere in der Home-App „Meine Stimme erkennen“ und „Persönliche Inhalte“, und lege dieses iPhone in „Wo ist?“ als Standortgerät fest.",
      "Teste zuerst auf dem iPhone, mit Siri in derselben Sprache wie auf dem HomePod: „Hey Siri, \(name)“. Ein neuer Name kann auf dem HomePod einige Minuten bis einen Tag brauchen.",
    ] },
    .it: { name, host in [
      "Invia il file al tuo iPhone (AirDrop) e tocca «Aggiungi comando rapido».",
      "Nell’app Comandi Rapidi, esegui «\(name)» una volta toccandolo e consenti la connessione a \(host).",
      "Apri i dettagli del comando rapido (ⓘ) e attiva «Consenti esecuzione quando bloccato» se lo vedi.",
      "Per HomePod: nell’app Casa, attiva «Riconosci la mia voce» e «Contenuti personali», e imposta questo iPhone come dispositivo di localizzazione in Dov’è.",
      "Prova prima sull’iPhone, con Siri nella stessa lingua dell’HomePod: «Ehi Siri, \(name)». Un nome nuovo può impiegare da qualche minuto a un giorno per funzionare su HomePod.",
    ] },
    .ptBR: { name, host in [
      "Envie o arquivo para o iPhone (AirDrop) e toque em “Adicionar Atalho”.",
      "No app Atalhos, execute “\(name)” uma vez tocando nele e permita a conexão com \(host).",
      "Abra os detalhes do atalho (ⓘ) e ative “Permitir Execução Quando Bloqueado”, se aparecer.",
      "Para o HomePod: no app Casa, ative “Reconhecer Minha Voz” e “Conteúdo Pessoal”, e defina este iPhone como dispositivo de localização no Buscar.",
      "Teste primeiro no iPhone, com a Siri no mesmo idioma do HomePod: “E aí Siri, \(name)”. Um nome novo pode levar de alguns minutos a um dia para funcionar no HomePod.",
    ] },
    .ru: { name, host in [
      "Отправьте файл на iPhone (AirDrop) и нажмите «Добавить».",
      "В приложении «Команды» запустите «\(name)» один раз, нажав на него, и разрешите подключение к \(host).",
      "Откройте сведения о команде (ⓘ) и включите «Запуск при\u{A0}заблокированном экране», если этот пункт есть.",
      "Для HomePod: в приложении «Дом» включите «Узнавание моего голоса» и «Личный контент», а в «Локаторе» сделайте этот iPhone устройством геопозиции.",
      "Сначала проверьте на iPhone (язык Siri должен совпадать с языком HomePod): «Привет, Siri, \(name)». Новое имя на HomePod может заработать через несколько минут или в течение суток.",
    ] },
    .ja: { name, host in [
      "ファイルを iPhone に送信し（AirDrop）、「ショートカットを追加」をタップします。",
      "「ショートカット」App で「\(name)」をタップして 1 回実行し、\(host) への接続を許可します。",
      "ショートカットの詳細（ⓘ）を開き、「ロック中に実行を許可」が表示されていればオンにします。",
      "HomePod：「ホーム」App で「自分の声を識別」と「個人的なコンテンツ」をオンにし、「探す」でこの iPhone を位置情報のデバイスに設定します。",
      "まず iPhone でテストします（iPhone の Siri の言語を HomePod と同じにします）：「Hey Siri、\(name)」。新しい名前が HomePod で使えるようになるまで、数分から 1 日かかることがあります。",
    ] },
    .ko: { name, host in [
      "파일을 iPhone으로 보낸 다음(AirDrop) “단축어 추가”를 탭합니다.",
      "“단축어” 앱에서 “\(name)”을(를) 탭하여 한 번 실행하고, \(host)에 연결하도록 허용합니다.",
      "단축어의 세부사항(ⓘ)을 열고, “잠겨 있는 동안 실행 허용”이 보이면 켭니다.",
      "HomePod: “홈” 앱에서 “나의 음성 인식”과 “개인용 콘텐츠”를 켜고, “나의\u{A0}찾기”에서 이 iPhone을 위치 기기로 설정합니다.",
      "먼저 iPhone에서 테스트합니다(iPhone의 Siri 언어를 HomePod과 같게): “Siri야, \(name)”. 새 이름은 HomePod에서 작동하기까지 몇 분에서 하루가 걸릴 수 있습니다.",
    ] },
    .zhHans: { name, host in [
      "把文件发送到 iPhone（隔空投送），然后轻点“添加快捷指令”。",
      "在“快捷指令” App 中轻点“\(name)”运行一次，并允许它连接 \(host)。",
      "打开该快捷指令的详细信息（ⓘ），如果看到“锁定时允许运行”，请打开。",
      "HomePod：在“家庭” App 中打开“识别我的声音”和“个人内容”（iOS 26 之前叫“个人请求”），并在“查找”中把这台 iPhone 设为定位设备。",
      "先在 iPhone 上测试（iPhone 的 Siri 语言要和 HomePod 的一致）：“嘿Siri，\(name)”。新名字在 HomePod 上可能要几分钟到一天才生效。",
    ] },
    .zhHant: { name, host in [
      "把檔案傳到 iPhone（AirDrop），然後點一下「加入捷徑」。",
      "在「捷徑」App 中點一下「\(name)」執行一次，並允許它連接 \(host)。",
      "打開該捷徑的詳細資訊（ⓘ），如果看到「鎖定時允許執行」，請將它打開。",
      "HomePod：在「家庭」App 中打開「辨識我的聲音」和「個人化內容」，並在「尋找」中把這台 iPhone 設為定位裝置。",
      "先在 iPhone 上測試（iPhone 的 Siri 語言要和 HomePod 的一致）：「嘿Siri，\(name)」。新名字在 HomePod 上可能要幾分鐘到一天才生效。",
    ] },
  ]
}
