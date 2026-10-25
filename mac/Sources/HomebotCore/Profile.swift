// What a Shortcut says and how it speaks, derived from the two language settings (Lang.swift).
// Siri language -> phrase, prompt, voice. iPhone language -> setup steps. The phrase rules are
// DESIGN §16.2: only correctness blocks (a name iOS would change, a name in use); the script,
// digits and leading command words are advice (DECISIONS item 29).
// Ported from src/shortcut/profile.ts; the rows themselves are in Catalogs.generated.swift.
import Foundation

/// One row per reply language (DESIGN §16).
struct PhraseRow: Sendable {
  struct BadStart: Sendable {
    let word: String
    /// A device failure (DECISIONS item 12, "问"): the advice is worded as a likely failure.
    let strong: Bool
    init(_ word: String, strong: Bool = false) {
      self.word = word
      self.strong = strong
    }
  }

  /// Whole-phrase check (ICU pattern, same source as the TypeScript regex): only this language's
  /// characters. Advice; defaults must pass.
  let script: String
  /// Words are separated by spaces, so a leading command word matches as a whole word only.
  let spaced: Bool
  /// Ranked defaults; the first one not in use becomes the default phrase.
  let products: [String]
  /// Leading words Siri may parse as its own intent; all advice.
  let badStarts: [BadStart]
  let promptWithBot: @Sendable (String) -> String
  let promptWithoutBot: String
  let probeName: String
  let labName: String

  func prompt(_ bot: String?) -> String { bot.map(promptWithBot) ?? promptWithoutBot }

  func scriptMatches(_ s: String) -> Bool {
    s.range(of: script, options: .regularExpression) != nil
  }
}

public struct PhraseProblem: Sendable, Equatable {
  public enum Code: String, Sendable {
    case wrongScript = "wrong-script"
    case badStart = "bad-start"
    case searchStart = "search-start"
    case unsafeChars = "unsafe-chars"
    case inUse = "in-use"
  }

  public let code: Code
  public let message: String
  /// Refused (true) or advice only (false).
  public let blocking: Bool
}

public struct ShortcutProfile: Sendable {
  public let siriLang: String
  public let phoneLang: Lang
  public let replyLang: ReplyLang
  public let name: String
  public let prompt: String
  public let speakLang: String
  public let probeName: String
  public let labName: String
  /// Other valid, unused phrases for this Siri language (none equal to `name`).
  public let alternatives: [String]
  /// Problems with `name`; a Shortcut is only built when none is `blocking`.
  public let problems: [PhraseProblem]

  /// The setup steps in the iPhone's language. Pass the name of the Shortcut actually built.
  public func steps(host: String, name: String? = nil) -> [String] {
    (Profile.phoneSteps[phoneLang] ?? Profile.phoneSteps[.en]!)(name ?? self.name, host)
  }
}

public enum Profile {
  /// Phrases of the user's usable Homebot Shortcuts, except the one being replaced. Pending ones
  /// count (they may be on the phone); all languages and kinds count (one iPhone).
  /// `chain`: what the build takes the phrase over from (`TokenStore.takeoverChain`).
  public static func takenPhrases(_ tokens: [(id: String, label: String, state: TokenState)], replaces: String? = nil, chain: Set<String> = []) -> [String] {
    tokens.filter { $0.state != .retired && $0.id != replaces && !chain.contains($0.id) }.map(\.label)
  }

  /// Only correctness blocks (DECISIONS item 29): a name iOS would change on import, and a name
  /// another Homebot Shortcut uses. How likely Siri is to hear the name is advice: tapping the
  /// Shortcut works whatever its name.
  /// The phrase a replacement keeps: the old Shortcut's, when it was made for the same reply
  /// language. A Shortcut for another language gets that language's default instead: the
  /// script rule is advice now, so it no longer drops a phrase from another language.
  public static func keptPhrase(_ old: TokenInfo?, siriLang: String) -> String? {
    guard let old, Langs.replyLang(old.siriLang ?? Langs.defaultSiriLang) == Langs.replyLang(siriLang) else { return nil }
    return old.label
  }

  static func problems(_ name: String, _ row: PhraseRow, taken: [String]) -> [PhraseProblem] {
    var p: [PhraseProblem] = []
    if !row.scriptMatches(name.precomposedStringWithCanonicalMapping) {
      p.append(PhraseProblem(code: .wrongScript, message: "Siri in this language may not hear \"\(name)\" (other scripts, digits or symbols), so saying it may not start the Shortcut. Tapping it always works.", blocking: false))
    }
    let lower = labelKey(name)
    // Spaced languages match whole words only ("Asking" is fine); Chinese and Japanese have no
    // word spaces.
    if let bad = row.badStarts.first(where: { lower == $0.word || lower.hasPrefix(row.spaced ? "\($0.word) " : $0.word) }) {
      p.append(bad.strong
        ? PhraseProblem(code: .searchStart, message: "On a Chinese HomePod, Siri took a phrase starting with \"\(bad.word)\" as a web search, so saying it will likely fail. Tapping it always works. Pick another if you can.", blocking: false)
        : PhraseProblem(code: .badStart, message: "A phrase starting with \"\(bad.word)\" may be taken by Siri as its own command. If Siri does that, pick another.", blocking: false))
    }
    // iOS names an imported Shortcut after its file name, so a name the file name would change
    // is not the name the user chose, nor the one the setup steps quote.
    if ShortcutMaker.safeFileName(name) != name {
      p.append(PhraseProblem(code: .unsafeChars, message: "iOS would change \"\(name)\" when it imports the Shortcut. Leave out / \\ : and control characters, and don't start with a dot.", blocking: true))
    }
    if taken.contains(where: { labelKey($0) == lower }) {
      p.append(PhraseProblem(code: .inUse, message: "Another of your Homebot Shortcuts already uses \"\(name)\". Siri can't tell them apart.", blocking: true))
    }
    return p
  }

  public struct ProfileError: Error, CustomStringConvertible, Equatable {
    public let description: String
  }

  /// The entry Shortcut's profile (DESIGN §20.5): a product phrase of the Siri language's table,
  /// never a bot's name (the phrase stands for every bot in the set), and the question prompt
  /// without a name. The phrase rules, kept phrase and uniqueness are the same as for any Shortcut.
  public static func entry(siriLang: String = Langs.defaultSiriLang, phoneLang: String = Langs.defaultPhoneLang.rawValue, name: String? = nil, keep: String? = nil, taken: [String] = []) throws -> ShortcutProfile {
    try make(botName: "", siriLang: siriLang, phoneLang: phoneLang, name: name, keep: keep, taken: taken)
  }

  /// - `name`: the user's own phrase; otherwise the kept phrase or the first usable default.
  /// - `keep`: the phrase of the Shortcut being replaced: the default when `name` is not given
  ///   and it passes every blocking rule, so a replacement keeps the phrase Siri learned.
  /// - `taken`: phrases of the user's other usable Shortcuts.
  public static func make(botName: String, siriLang: String = Langs.defaultSiriLang, phoneLang: String = Langs.defaultPhoneLang.rawValue, name: String? = nil, keep: String? = nil, taken: [String] = []) throws -> ShortcutProfile {
    guard Langs.isSiriLang(siriLang) else { throw ProfileError(description: "unsupported Siri language: \(siriLang)") }
    guard let phone = Lang(rawValue: phoneLang) else { throw ProfileError(description: "unsupported iPhone language: \(phoneLang)") }
    let reply = Langs.replyLang(siriLang)
    let row = PhraseRow.rows[reply]!
    let bot = botName.trimmingCharacters(in: jsWhitespace)
    let botFits = problems(bot, row, taken: []).isEmpty
    // Product phrases first (one is proved on a device), then the bot's own name if it fits.
    var candidates: [String] = []
    for c in row.products + (botFits ? [bot] : []) where !candidates.contains(c) { candidates.append(c) }
    let usable = candidates.filter { problems($0, row, taken: taken).isEmpty }
    // Only blocking problems disqualify the old phrase; advice alone never changes a phrase Siri
    // already learned (milestone re-review S2).
    let keepTrimmed = keep?.trimmingCharacters(in: jsWhitespace)
    let kept = keepTrimmed.flatMap { k in !k.isEmpty && !problems(k, row, taken: taken).contains(where: \.blocking) ? k : nil }
    let finalName = (name ?? kept ?? usable.first ?? row.products.first ?? "").trimmingCharacters(in: jsWhitespace)
    guard !finalName.isEmpty, finalName.utf16.count <= 60 else { throw ProfileError(description: "Shortcut name must be 1-60 characters") }
    return ShortcutProfile(
      siriLang: siriLang, phoneLang: phone, replyLang: reply, name: finalName,
      // The question names the phrase the user said, never the bot: a bot called "homebot" read
      // as the app's name (S25). An entry Shortcut (no bot) asks without a name.
      prompt: row.prompt(!bot.isEmpty && problems(finalName, row, taken: []).isEmpty ? finalName : nil),
      speakLang: siriLang, // Speak Text voice follows Siri's language, not the iPhone's
      probeName: row.probeName, labName: row.labName,
      alternatives: usable.filter { labelKey($0) != labelKey(finalName) },
      problems: problems(finalName, row, taken: taken))
  }
}
