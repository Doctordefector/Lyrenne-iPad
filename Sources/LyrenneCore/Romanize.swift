import Foundation

/// Latin-letter readings of lyrics in other scripts, shown under each line. Desktop's
/// Romanizer.kt does the same with ICU4J and kuromoji; here the system has both built in:
/// CFStringTokenizer reads Japanese kanji as Japanese words (a plain transliteration reads them
/// as Mandarin), and StringTransform spells everything else. Korean is written out by hand,
/// as on desktop, because the system's Hangul-Latin goes letter by letter ("salanghae").
/// The system parts are Apple-only; on Linux only Korean is romanized.
public enum Romanize {

    /// True when [text] has a letter from a script worth romanizing
    public static func needed(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isForeignLetter)
    }

    /// The romanized form of every line that needs one, keyed by the line's own text. The whole
    /// song at once: any kana in it makes its kanji-only lines Japanese rather than Chinese.
    public static func lines(_ lines: [String]) -> [String: String] {
        let japanese = lines.contains { $0.unicodeScalars.contains(where: isKana) }
        let cyrillic = cyrillicTransform(lines)
        var out: [String: String] = [:]
        for line in Set(lines) where needed(line) {
            let scalars = line.unicodeScalars
            let latin: String?
            if japanese, scalars.contains(where: { isKana($0) || isHan($0) }) {
                latin = Self.japanese(line)
            } else if scalars.contains(where: Korean.isSyllable) {
                let korean = Korean.romanize(line)
                latin = toLatin(korean) ?? korean
            } else if scalars.contains(where: isCyrillic) {
                latin = bgn(line, cyrillic)
            } else {
                latin = toLatin(line)
            }
            if let latin = latin.map(tidy), !latin.isEmpty, latin != line { out[line] = latin }
        }
        return out
    }

    // MARK: Japanese

    static func japanese(_ line: String) -> String? {
        #if canImport(Darwin)
        let text = line as NSString
        let tokenizer = CFStringTokenizerCreate(nil, line as CFString, CFRange(location: 0, length: text.length),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var words: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let surface = text.substring(with: NSRange(location: range.location, length: range.length))
            if surface.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // The particles are written は, へ, を and said wa, e, o
            switch surface {
            case "は": words.append("wa"); continue
            case "へ": words.append("e"); continue
            case "を": words.append("o"); continue
            default: break
            }
            let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            if let reading, !reading.isEmpty {
                words.append(reading)
            } else if surface.unicodeScalars.contains(where: isKana) {
                words.append(toLatin(surface) ?? surface)
            } else {
                // Punctuation and Latin words as written. A kanji with no reading stays too:
                // a Chinese reading would be wrong rather than merely missing.
                words.append(punctuation(surface))
            }
        }
        // The tokenizer splits a small っ off the sound it doubles (行っ / た) and spells it "~tsu"
        // on its own. Joined back: "itta", not "i~tsu ta".
        var joined: [String] = []
        for word in words {
            if let last = joined.last, last.hasSuffix("~tsu"), let first = word.first, first.isLetter {
                joined[joined.count - 1] = String(last.dropLast(4)) + String(first) + word
            } else {
                joined.append(word)
            }
        }
        return joined.map { $0.replacingOccurrences(of: "~tsu", with: "") }.joined(separator: " ")
        #else
        return nil
        #endif
    }

    static let japanesePunctuation: [Character: String] = [
        "、": ",", "。": ".", "！": "!", "？": "?", "「": "\"", "」": "\"", "『": "\"", "』": "\"",
        "（": "(", "）": ")", "・": " ", "〜": "~", "～": "~", "　": " ",
    ]

    static func punctuation(_ s: String) -> String {
        s.map { japanesePunctuation[$0] ?? String($0) }.joined()
    }

    // MARK: Cyrillic

    /// BGN/PCGN for the language the song's letters point to. The system default (ISO 9) writes
    /// я as "â"; BGN gives the "ya" people expect, but spells и differently per language.
    static func cyrillicTransform(_ lines: [String]) -> String {
        let all = lines.joined(separator: "\n").lowercased()
        if all.contains(where: { "іїєґ".contains($0) }) { return "Ukrainian-Latin/BGN" }
        if all.contains("ў") { return "Belarusian-Latin/BGN" }
        if all.contains(where: { "ђћџ".contains($0) }) { return "Serbian-Latin/BGN" }
        if all.contains(where: { "ѓќѕ".contains($0) }) { return "Macedonian-Latin/BGN" }
        return "Russian-Latin/BGN"
    }

    /// Word by word: BGN capitalises a whole digraph for one capital, which turns the word "Я"
    /// into "YA". Soft and hard sign primes are dropped, as lyrics don't write them.
    static func bgn(_ line: String, _ id: String) -> String? {
        #if canImport(Darwin)
        let transform = StringTransform(id)
        let spelled = line.replacing(/\p{L}+/) { match -> String in
            let word = String(match.output)
            let latin = word.applyingTransform(transform, reverse: false) ?? toLatin(word) ?? word
            if word.count == 1, word.first!.isUppercase { return latin.lowercased().capitalized }
            return latin
        }
        return spelled.replacingOccurrences(of: "ʹ", with: "").replacingOccurrences(of: "ʺ", with: "")
        #else
        return nil
        #endif
    }

    // MARK: Plumbing

    static func toLatin(_ s: String) -> String? {
        #if canImport(Darwin)
        return s.applyingTransform(.toLatin, reverse: false)
        #else
        return nil
        #endif
    }

    static func tidy(_ s: String) -> String {
        s.replacing(/\s+/, with: " ")
            .replacing(#/ ([,.!?)"])/#) { String($0.output.1) }
            .replacingOccurrences(of: "( ", with: "(")
            .trimmingCharacters(in: .whitespaces)
    }

    static func isKana(_ s: Unicode.Scalar) -> Bool {
        // ー (30FC) sits in the Katakana block but is shared punctuation; it alone isn't Japanese
        s.value != 0x30FC && ((0x3041...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
            || (0x31F0...0x31FF).contains(s.value) || (0xFF66...0xFF9D).contains(s.value))
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            || (0xF900...0xFAFF).contains(s.value) || (0x20000...0x2A6DF).contains(s.value)
    }

    static func isCyrillic(_ s: Unicode.Scalar) -> Bool { (0x0400...0x052F).contains(s.value) }

    /// Letters outside Latin. Arabic, Hebrew, Thai and their neighbours are left out on purpose,
    /// as on desktop: they leave vowels unwritten, so a letter-by-letter spelling is unreadable.
    static func isForeignLetter(_ s: Unicode.Scalar) -> Bool {
        guard s.properties.isAlphabetic else { return false }
        let skipped: [ClosedRange<UInt32>] = [
            0x0000...0x02FF, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFF21...0xFF5A, // Latin
            0x0590...0x05FF, 0xFB1D...0xFB4F, // Hebrew
            0x0600...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF, // Arabic, Syriac, Thaana
            0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, // Thai, Lao, Myanmar, Khmer
        ]
        return !skipped.contains { $0.contains(s.value) }
    }
}

/// Hangul in Revised Romanization, the same rules as desktop's KoreanRomanizer.kt. Korean is
/// said across syllables, so each final consonant is resolved with the initial after it:
/// carried over before a vowel (싶어 sipeo), palatalized before 이 (같이 gachi), nasalized
/// before ㄴ and ㅁ (합니다 hamnida), silent ㅎ dropped (좋아 joa). The common rules, not all.
enum Korean {
    static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    static let vowels = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo",
                         "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    /// How each final sounds at the end of a word or before another consonant; 0 is none
    static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l",
                         "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    /// Before a vowel: the part of the final that stays, and the part that starts the next syllable
    static let carried: [(String, String)] = [
        ("", ""), ("", "g"), ("", "kk"), ("k", "s"), ("", "n"), ("n", "j"), ("n", ""), ("", "d"),
        ("", "r"), ("l", "g"), ("l", "m"), ("l", "b"), ("l", "s"), ("l", "t"), ("l", "p"), ("", "r"),
        ("", "m"), ("", "b"), ("p", "s"), ("", "s"), ("", "ss"), ("ng", ""), ("", "j"), ("", "ch"),
        ("", "k"), ("", "t"), ("", "p"), ("", ""),
    ]

    static func isSyllable(_ s: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(s.value) }

    static func romanize(_ text: String) -> String {
        var out = ""
        var word: [(lead: Int, vowel: Int, coda: Int)] = []
        func flush() {
            guard let first = word.first else { return }
            var initial = initials[first.lead]
            for (k, syllable) in word.enumerated() {
                out += initial + vowels[syllable.vowel]
                guard k + 1 < word.count else { out += finals[syllable.coda]; break }
                let next = word[k + 1]
                let (finalText, nextInitial) = join(syllable.coda, next.lead, next.vowel)
                out += finalText
                initial = nextInitial
            }
            word = []
        }
        for s in text.unicodeScalars {
            if isSyllable(s) {
                let v = Int(s.value) - 0xAC00
                word.append((v / (21 * 28), v % (21 * 28) / 28, v % 28))
            } else {
                flush()
                out.unicodeScalars.append(s)
            }
        }
        flush()
        return out
    }

    /// A final against the next syllable's initial (and vowel, for 이)
    static func join(_ coda: Int, _ nextInitial: Int, _ nextVowel: Int) -> (String, String) {
        let plain = initials[nextInitial]
        guard coda != 0 else { return ("", plain) }
        let sound = finals[coda]
        switch nextInitial {
        case 11: // ㅇ: the final carries over
            if coda == 25 && nextVowel == 20 { return ("", "ch") } // ㅌ+이
            if coda == 7 && nextVowel == 20 { return ("", "j") }   // ㄷ+이
            return carried[coda]
        case _ where coda == 27: // ㅎ final
            switch nextInitial {
            case 0: return ("", "k")
            case 3: return ("", "t")
            case 12: return ("", "ch")
            case 9: return ("", "ss")
            case 2: return ("n", "n")
            default: return ("", plain)
            }
        case 2, 6: // ㄴ, ㅁ: nasalization
            switch sound {
            case "k": return ("ng", plain)
            case "t": return ("n", plain)
            case "p": return ("m", plain)
            case "l" where nextInitial == 2: return ("l", "l")
            default: return (sound, plain)
            }
        case 5: // ㄹ
            switch sound {
            case "n", "l": return ("l", "l")
            case "k": return ("ng", "n")
            case "t": return ("n", "n")
            case "p": return ("m", "n")
            default: return (sound, "n")
            }
        default:
            return (sound, plain)
        }
    }
}
