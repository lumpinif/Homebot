// The app's String Catalog: every key in all 11 languages, the same {placeholders} as English,
// and the lookups the views use (DECISIONS item 22).
import Foundation
import Testing

import HomebotCore
@testable import HomebotUI

let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../App/Localizable.xcstrings").standardized

func placeholders(_ s: String) -> Set<String> {
  Set(s.matches(of: /\{([a-zA-Z]+)\}/).map { String($0.1) })
}

@Suite struct L10nTests {
  let catalog: [Lang: [String: String]]
  init() throws { catalog = try L10n.catalog(catalogURL) }

  @Test func everyKeyInEveryLanguage() {
    #expect(Set(catalog.keys) == Set(Lang.allCases))
    #expect(UIStringKeys.all.count > 200)
    for lang in Lang.allCases {
      let t = catalog[lang] ?? [:]
      let missing = UIStringKeys.all.filter { (t[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
      #expect(missing.isEmpty, "\(lang.rawValue) lacks \(missing)")
      #expect(Set(t.keys) == Set(UIStringKeys.all), "\(lang.rawValue) has keys the generator did not list")
    }
  }

  /// Home headline's spoken label names Grok Bot and Siri once each, in every language.
  @Test @MainActor func heroLabelIsPlainText() throws {
    for lang in Lang.allCases {
      let title = try #require(catalog[lang]?["heroTitle"])
      let label = Hero.plain(title)
      #expect(!label.contains("{"), "\(lang)")
      #expect(label.components(separatedBy: "Siri").count == 2, "\(lang)")
      #expect(label.contains("Grok Bot"), "\(lang)")
    }
  }

  @Test func placeholdersMatchEnglish() {
    let en = catalog[.en] ?? [:]
    for lang in Lang.allCases where lang != .en {
      for key in UIStringKeys.all {
        guard let e = en[key], let t = catalog[lang]?[key] else { continue }
        #expect(placeholders(t) == placeholders(e), "\(lang.rawValue) \(key)")
      }
    }
  }

  @Test func appOnlyKeysAreNotTheWebPagesKeys() {
    #expect(UIStringKeys.appOnly.isSubset(of: Set(UIStringKeys.all)))
    #expect(UIStringKeys.appOnly.contains("homeTitle"))
    #expect(!UIStringKeys.appOnly.contains("accountTitle"))
  }

  @Test func accessorsFormatsAndOutcomes() {
    let de = Tr(lang: .de, table: catalog[.de]!, fallback: catalog[.en]!)
    #expect(de.homeTitle == catalog[.de]!["homeTitle"])
    #expect(de.fmt("{n} of {n} · {x}", ["n": "2", "x": "y"]) == "2 of 2 · y")
    #expect(de.outcomeLabel("answered") == catalog[.de]!["outcome.answered"])
    #expect(de.outcomeLabel("not-sent:busy") == catalog[.de]!["outcome.not-sent"])
    #expect(de.outcomeLabel("something-new") == catalog[.de]!["outcome.other"])
    #expect(de.errors("auth") == catalog[.de]!["errors.auth"])
    #expect(de.errors("no-such-code") == nil)
    // A key missing in a language falls back to English, then to the key.
    let thin = Tr(lang: .ja, table: [:], fallback: ["homeTitle": "Home"])
    #expect(thin["homeTitle"] == "Home")
    #expect(thin["nope"] == "nope")
  }

  @Test func systemLanguageMapsToAPageLanguage() {
    #expect(L10n.preferred(["zh-Hans-CN"]) == .zhHans)
    #expect(L10n.preferred(["zh-Hant-TW"]) == .zhHant)
    #expect(L10n.preferred(["zh-HK"]) == .zhHant)
    #expect(L10n.preferred(["pt-PT"]) == .ptBR)
    #expect(L10n.preferred(["de-AT", "en"]) == .de)
    #expect(L10n.preferred(["nl-NL", "ja-JP"]) == .ja)
    #expect(L10n.preferred(["nl-NL"]) == .en)
  }
}
