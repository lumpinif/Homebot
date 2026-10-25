// The entry flow's choosing phase (DESIGN §20.5): which bot a "one phrase for all my bots" run
// talks to. The gateway speaks a numbered menu, matches the answer against the menu as it was
// spoken (a snapshot, never the live list), and speaks the choice back before the question.
// Nothing said while choosing reaches a bot or is stored. Pure: no I/O.
//
// The spoken lines and word lists below are Claude's drafts for the eleven languages; no native
// speaker has reviewed them (STATUS), and none has been tried on a HomePod yet (DESIGN §20.5, S6).
import Foundation

/// One bot offered in the menu: the grant it stands for and the name spoken for it at the time.
public struct EntryChoice: Sendable, Equatable {
  public var key: String
  public var sessionId: String
  /// "What Siri calls this bot" (the display name).
  public var name: String
  public var aliases: [String]

  public init(key: String, sessionId: String, name: String, aliases: [String] = []) {
    self.key = key
    self.sessionId = sessionId
    self.name = name
    self.aliases = aliases
  }

  public init(_ bot: Bot) {
    self.init(key: bot.key, sessionId: bot.sessionId, name: bot.name, aliases: bot.aliases)
  }

  public var grant: BotGrant { BotGrant(key: key, sessionId: sessionId) }
  /// The name spoken for this bot: its first alias, else its display name.
  public var spoken: String { aliases.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? name }
}

/// Spoken lines and word lists of the choosing phase, per reply language.
public struct ChooserText: Sendable {
  /// "Which bot?" before the numbered names.
  let ask: String
  /// Between "1" and the name, and between items, and at the end.
  let itemSeparator: String
  let menuEnd: String
  let confirm: @Sendable (String) -> String
  let notFound: String
  /// Between the chosen bot's name and the question prompt ("拆解师。想问什么？").
  let chosenSeparator: String
  /// Number words 1–9 (index 0 is "one"); digits always work too.
  let numbers: [[String]]
  /// Words around a number that still mean the number ("第二个", "number two").
  let numberPrefixes: [String]
  let numberSuffixes: [String]
  let yes: [String]
  let no: [String]

  public static func of(_ lang: ReplyLang) -> ChooserText { table[lang] ?? table[.en]! }

  public func menu(_ items: [EntryChoice]) -> String {
    let list = items.enumerated().map { "\($0.offset + 1) \($0.element.spoken)" }.joined(separator: itemSeparator)
    // No space after a full-width question mark (Chinese, Japanese).
    return "\(ask)\(ask.hasSuffix("？") ? "" : " ")\(list)\(menuEnd)"
  }

  public func chosen(_ name: String, prompt: String) -> String { "\(name)\(chosenSeparator)\(prompt)" }

  static let table: [ReplyLang: ChooserText] = [
    .en: ChooserText(
      ask: "Which bot?", itemSeparator: ", ", menuEnd: ".", confirm: { "Did you mean \($0)?" }, notFound: "I didn't find that bot.", chosenSeparator: ". ",
      numbers: [["one"], ["two", "to", "too"], ["three"], ["four", "for"], ["five"], ["six"], ["seven"], ["eight"], ["nine"]],
      numberPrefixes: ["number", "the"], numberSuffixes: [],
      yes: ["yes", "yeah", "yep", "correct", "right", "thats right"], no: ["no", "nope", "wrong", "not that one"]),
    .es: ChooserText(
      ask: "¿Qué bot?", itemSeparator: ", ", menuEnd: ".", confirm: { "¿Te refieres a \($0)?" }, notFound: "No encontré ese bot.", chosenSeparator: ". ",
      numbers: [["uno", "una"], ["dos"], ["tres"], ["cuatro"], ["cinco"], ["seis"], ["siete"], ["ocho"], ["nueve"]],
      numberPrefixes: ["el número", "número", "el"], numberSuffixes: [],
      yes: ["sí", "si", "correcto", "eso", "exacto"], no: ["no", "incorrecto", "ese no"]),
    .fr: ChooserText(
      ask: "Quel bot ?", itemSeparator: ", ", menuEnd: ".", confirm: { "Tu veux dire \($0) ?" }, notFound: "Je n’ai pas trouvé ce bot.", chosenSeparator: ". ",
      numbers: [["un", "une"], ["deux"], ["trois"], ["quatre"], ["cinq"], ["six"], ["sept"], ["huit"], ["neuf"]],
      numberPrefixes: ["le numéro", "numéro", "le"], numberSuffixes: [],
      yes: ["oui", "exact", "cest ça", "ouais"], no: ["non", "pas ça", "pas celui-là"]),
    .de: ChooserText(
      ask: "Welcher Bot?", itemSeparator: ", ", menuEnd: ".", confirm: { "Meinst du \($0)?" }, notFound: "Diesen Bot habe ich nicht gefunden.", chosenSeparator: ". ",
      numbers: [["eins", "ein", "eine"], ["zwei"], ["drei"], ["vier"], ["fünf"], ["sechs"], ["sieben"], ["acht"], ["neun"]],
      numberPrefixes: ["nummer"], numberSuffixes: [],
      yes: ["ja", "genau", "richtig"], no: ["nein", "falsch", "nicht der"]),
    .it: ChooserText(
      ask: "Quale bot?", itemSeparator: ", ", menuEnd: ".", confirm: { "Intendi \($0)?" }, notFound: "Non ho trovato quel bot.", chosenSeparator: ". ",
      numbers: [["uno", "una"], ["due"], ["tre"], ["quattro"], ["cinque"], ["sei"], ["sette"], ["otto"], ["nove"]],
      numberPrefixes: ["il numero", "numero", "il"], numberSuffixes: [],
      yes: ["sì", "si", "esatto", "giusto"], no: ["no", "sbagliato", "non quello"]),
    .ptBR: ChooserText(
      ask: "Qual bot?", itemSeparator: ", ", menuEnd: ".", confirm: { "Você quis dizer \($0)?" }, notFound: "Não encontrei esse bot.", chosenSeparator: ". ",
      numbers: [["um", "uma"], ["dois", "duas"], ["três", "tres"], ["quatro"], ["cinco"], ["seis"], ["sete"], ["oito"], ["nove"]],
      numberPrefixes: ["o número", "número", "o"], numberSuffixes: [],
      yes: ["sim", "isso", "certo"], no: ["não", "nao", "errado"]),
    .ru: ChooserText(
      ask: "Какой бот?", itemSeparator: ", ", menuEnd: ".", confirm: { "Вы имели в виду \($0)?" }, notFound: "Я не нашёл такого бота.", chosenSeparator: ". ",
      numbers: [["один", "первый"], ["два", "второй"], ["три", "третий"], ["четыре", "четвёртый", "четвертый"], ["пять", "пятый"], ["шесть", "шестой"], ["семь", "седьмой"], ["восемь", "восьмой"], ["девять", "девятый"]],
      numberPrefixes: ["номер"], numberSuffixes: [],
      yes: ["да", "верно", "правильно"], no: ["нет", "неверно", "не то"]),
    .ja: ChooserText(
      ask: "どのボットですか？", itemSeparator: "、", menuEnd: "。", confirm: { "\($0)ですか？" }, notFound: "そのボットは見つかりませんでした。", chosenSeparator: "。",
      numbers: [["一", "いち"], ["二", "に"], ["三", "さん"], ["四", "よん", "し"], ["五", "ご"], ["六", "ろく"], ["七", "なな", "しち"], ["八", "はち"], ["九", "きゅう", "く"]],
      numberPrefixes: [], numberSuffixes: ["番目", "番"],
      yes: ["はい", "うん", "そう", "そうです"], no: ["いいえ", "違う", "ちがう", "違います"]),
    .ko: ChooserText(
      ask: "어느 봇인가요?", itemSeparator: ", ", menuEnd: ".", confirm: { "\($0) 맞나요?" }, notFound: "그 봇을 찾지 못했어요.", chosenSeparator: ". ",
      // "네" alone is "yes", so four is "넷" or "네번째" only.
      numbers: [["일", "하나", "한", "첫", "첫번째"], ["이", "둘", "두", "두번째"], ["삼", "셋", "세", "세번째"], ["사", "넷", "네번째"], ["오", "다섯"], ["육", "여섯"], ["칠", "일곱"], ["팔", "여덟"], ["구", "아홉"]],
      numberPrefixes: [], numberSuffixes: ["번째", "번"],
      yes: ["네", "응", "예", "맞아", "맞아요"], no: ["아니", "아니요", "아니야", "틀려"]),
    .zhCN: ChooserText(
      ask: "问哪个机器人？", itemSeparator: "，", menuEnd: "。", confirm: { "是\($0)吗？" }, notFound: "没有找到这个机器人。", chosenSeparator: "。",
      numbers: [["一", "幺"], ["二", "两"], ["三"], ["四"], ["五"], ["六"], ["七"], ["八"], ["九"]],
      numberPrefixes: ["第"], numberSuffixes: ["个", "号"],
      yes: ["是", "是的", "对", "对的", "嗯", "好", "好的"], no: ["不对", "不是", "不", "错了"]),
    .zhTW: ChooserText(
      ask: "問哪個機器人？", itemSeparator: "，", menuEnd: "。", confirm: { "是\($0)嗎？" }, notFound: "沒有找到這個機器人。", chosenSeparator: "。",
      numbers: [["一"], ["二", "兩"], ["三"], ["四"], ["五"], ["六"], ["七"], ["八"], ["九"]],
      numberPrefixes: ["第"], numberSuffixes: ["個", "號"],
      yes: ["是", "是的", "對", "對的", "嗯", "好", "好的"], no: ["不對", "不是", "不", "錯了"]),
  ]
}

public enum Chooser {
  public enum Match: Sendable, Equatable {
    /// An exact name or alias, or the number: spoken back as the next prompt.
    case exact(Int)
    /// A close name: asked back as a yes/no question.
    case fuzzy(Int)
    case none
  }

  /// NFKC, case-folded, punctuation, symbols and spaces removed (DESIGN §20.5 rule 2).
  public static func norm(_ s: String) -> String {
    let t = s.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
    return String(String.UnicodeScalarView(t.unicodeScalars.filter { u in
      let p = u.properties
      switch p.generalCategory {
      case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format: return false
      case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation: return false
      case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return false
      default: return !p.isWhitespace
      }
    }))
  }

  static func words(_ list: [String]) -> Set<String> { Set(list.map(norm)) }

  public static func isYes(_ s: String, _ lang: ReplyLang) -> Bool { words(ChooserText.of(lang).yes).contains(norm(s)) }
  public static func isNo(_ s: String, _ lang: ReplyLang) -> Bool { words(ChooserText.of(lang).no).contains(norm(s)) }

  /// The menu number a whole utterance says (1-based), if any.
  public static func number(_ s: String, _ lang: ReplyLang) -> Int? {
    let t = ChooserText.of(lang)
    var u = norm(s)
    for (i, ws) in t.numbers.enumerated() where ws.map(norm).contains(u) { return i + 1 }
    for p in t.numberPrefixes.map(norm).sorted(by: { $0.count > $1.count }) where !p.isEmpty && u.hasPrefix(p) && u.count > p.count {
      u = String(u.dropFirst(p.count))
      break
    }
    for x in t.numberSuffixes.map(norm).sorted(by: { $0.count > $1.count }) where !x.isEmpty && u.hasSuffix(x) && u.count > x.count {
      u = String(u.dropLast(x.count))
      break
    }
    if u.count == 1, let d = u.first?.wholeNumberValue, (1...9).contains(d), u.first!.isASCII { return d }
    for (i, ws) in t.numbers.enumerated() where ws.map(norm).contains(u) { return i + 1 }
    return nil
  }

  /// Every word that can never be a bot name in `lang`: numbers, yes/no words, end words.
  static func reserved(_ lang: ReplyLang) -> Set<String> {
    let t = ChooserText.of(lang)
    var r = words(t.yes).union(words(t.no)).union(words(t.numbers.flatMap { $0 }))
    r.formUnion((1...9).map(String.init))
    r.formUnion(words(Conversation.endWords.values.flatMap { $0 }))
    return r
  }

  /// The names of entry `i` that can be matched by name: not empty, not a reserved word, and not
  /// the same (normalized) as any name of another entry in the menu.
  public static func matchableNames(_ items: [EntryChoice], _ i: Int, _ lang: ReplyLang) -> [String] {
    let res = reserved(lang)
    let others = Set(items.enumerated().filter { $0.offset != i }.flatMap { ([$0.element.name] + $0.element.aliases).map(norm) })
    // A name that reads as a number ("第二个") means that number, never this bot.
    return Array(Set(([items[i].name] + items[i].aliases).map(norm))).filter { !$0.isEmpty && !res.contains($0) && !others.contains($0) && number($0, lang) == nil }.sorted()
  }

  /// Names in a set that can only be chosen by number (the app warns about them, §20.5 rule 2).
  public static func ambiguousNames(_ items: [EntryChoice], _ lang: ReplyLang) -> [String] {
    items.indices.filter { matchableNames(items, $0, lang).isEmpty }.map { items[$0].name }
  }

  /// Match an utterance against the menu as spoken: an exact name or alias, then the number,
  /// then a close name (edit distance at most 1 per 4 characters, at least 2 better than the
  /// second best entry). For Mandarin, a name that is not close in characters may still be close
  /// in sound: the same rule is applied once more to toneless pinyin, because Siri often writes a
  /// name with other characters of the same sound ("拆姐诗" for "拆解师"). A close match is never
  /// taken as said: it is asked back as a yes/no question.
  public static func match(_ utterance: String, _ items: [EntryChoice], _ lang: ReplyLang) -> Match {
    let u = norm(utterance)
    guard !u.isEmpty, !items.isEmpty else { return .none }
    let names = items.indices.map { matchableNames(items, $0, lang) }
    if let i = names.firstIndex(where: { $0.contains(u) }) { return .exact(i) }
    // A number means its menu position or nothing; a yes, no or end word is never a name.
    if let n = number(utterance, lang) { return n <= items.count ? .exact(n - 1) : .none }
    if reserved(lang).contains(u) { return .none }
    // Every name competes for the margin, also the ones that can't be chosen by name: two
    // entries that look or sound alike are never guessed.
    let all = items.map { ([$0.name] + $0.aliases).map(norm).filter { !$0.isEmpty } }
    if let i = closest(u, all) { return names[i].isEmpty ? .none : .fuzzy(i) }
    if lang == .zhCN || lang == .zhTW, let i = closest(pinyin(u), all.map { $0.map(pinyin) }) { return names[i].isEmpty ? .none : .fuzzy(i) }
    return .none
  }

  /// The one entry within 1 edit per 4 characters of `u`, at least 2 edits better than the next.
  static func closest(_ u: String, _ names: [[String]]) -> Int? {
    let us = Array(u.unicodeScalars)
    var scored: [(i: Int, d: Int, ok: Bool)] = []
    for (i, ns) in names.enumerated() {
      var best: (d: Int, ok: Bool)?
      for n in ns where !n.isEmpty {
        let s = Array(n.unicodeScalars)
        let d = editDistance(us, s)
        let ok = d <= s.count / 4
        if best == nil || d < best!.d { best = (d, ok) }
      }
      if let best { scored.append((i, best.d, best.ok)) }
    }
    scored.sort { $0.d < $1.d }
    guard let first = scored.first, first.ok else { return nil }
    if scored.count > 1, scored[1].d < first.d + 2 { return nil }
    return first.i
  }

  /// A normalized string's sound for Mandarin: Han characters as toneless pinyin, letters only
  /// ("拆解师" -> "chaijieshi"). Other characters pass through lower-cased.
  static func pinyin(_ s: String) -> String {
    let latin = s.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
    return norm(latin)
  }

  static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
      var cur = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
      }
      prev = cur
    }
    return prev[b.count]
  }
}

/// The start of a one-phrase exchange as Siri would speak it, for previews in the app and the CLI:
/// the phrase, then the bot's name and the question (one bot), or the menu, the first bot's name
/// as the answer, and the choice spoken back (several bots). The lines come from the same catalogs
/// the gateway speaks from.
public enum EntryPreview {
  public struct Line: Sendable, Equatable {
    /// Said by the user (else by Siri).
    public var user: Bool
    public var text: String

    public init(user: Bool, text: String) {
      self.user = user
      self.text = text
    }
  }

  public static func lines(phrase: String, bots: [EntryChoice], siriLang: String) -> [Line] {
    let lang = Langs.replyLang(siriLang)
    let t = ChooserText.of(lang)
    let prompt = PhraseRow.rows[lang]?.promptWithoutBot ?? Messages.of(lang).more
    var out = [Line(user: true, text: Langs.heySiri(siriLang, phrase))]
    let items = Array(bots.prefix(TokenStore.maxBots))
    guard let first = items.first else { return out }
    if items.count == 1 {
      out.append(Line(user: false, text: t.chosen(first.spoken, prompt: prompt)))
    } else {
      out.append(Line(user: false, text: t.menu(items)))
      out.append(Line(user: true, text: first.spoken))
      out.append(Line(user: false, text: t.chosen(first.spoken, prompt: prompt)))
    }
    return out
  }
}
