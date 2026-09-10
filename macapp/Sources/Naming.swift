import Foundation

/// A small wrapper so the ported patterns read like their Python originals.
struct RE {
    let re: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        // These patterns are compile-time constants; a failure is a bug.
        re = try! NSRegularExpression(pattern: pattern, options: opts)
    }

    private func full(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    func matches(_ s: String) -> Bool {
        re.firstMatch(in: s, range: full(s)) != nil
    }

    /// True when a match starts at the beginning of the string.
    func matchesPrefix(_ s: String) -> Bool {
        guard let m = re.firstMatch(in: s, range: full(s)) else { return false }
        return m.range.location == 0
    }

    func replacing(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: full(s), withTemplate: template)
    }

    func group(_ s: String, _ n: Int) -> String? {
        guard let m = re.firstMatch(in: s, range: full(s)), n < m.numberOfRanges,
              let r = Range(m.range(at: n), in: s) else { return nil }
        return String(s[r])
    }
}

enum Naming {

    // MARK: - Vocabulary

    /// Instrument names. A header line matching one of these is almost
    /// certainly the part name, so it outranks positional guesswork.
    static let instrumentWords: [String] = [
        // scores
        #"full\s+score"#, #"conductor'?s?\s+score"#, #"condensed\s+score"#, #"short\s+score"#,
        #"\bscore\b"#, #"\bconductor\b"#, #"lead\s+sheet"#, #"chord\s+chart"#, #"rhythm\s+chart"#,
        // voices
        #"soprano"#, #"\balto\b"#, #"\btenor\b"#, #"\bbaritone\b"#, #"\bbass\b"#,
        #"\bsatb\b"#, #"\bsab\b"#, #"\bssa\b"#, #"\bttbb\b"#, #"\bsa\b"#, #"\btb\b"#,
        #"\bvoice\b"#, #"\bvocals?\b"#, #"\bchoir\b"#, #"\bchorus\b"#, #"\bmelody\b"#,
        // keyboards
        #"\bpiano\b"#, #"keyboard"#, #"synth(esi[sz]er)?"#, #"\borgan\b"#, #"rhodes"#,
        #"celesta"#, #"harpsichord"#, #"accordion"#,
        // guitars / bass
        #"guitar"#, #"\bgtr\b"#, #"\bbanjo\b"#, #"ukulele"#, #"mandolin"#,
        // percussion
        #"drum\s*set"#, #"drum\s*kit"#, #"\bdrums?\b"#, #"percussion"#, #"\bperc\b"#,
        #"vibraphone"#, #"\bvibes\b"#, #"marimba"#, #"xylophone"#, #"glockenspiel"#,
        #"\bbells\b"#, #"\bmallets\b"#, #"timpani"#, #"\bcymbals?\b"#, #"\bsnare\b"#,
        #"congas?"#, #"bongos?"#, #"tambourine"#, #"aux(iliary)?\s+perc"#,
        // woodwinds
        #"\bflute\b"#, #"piccolo"#, #"\boboe\b"#, #"english\s+horn"#, #"clarinet"#,
        #"bassoon"#, #"contrabassoon"#, #"saxophone"#, #"\bsax\b"#, #"recorder"#,
        // brass
        #"trumpet"#, #"cornet"#, #"flugelhorn"#, #"french\s+horn"#, #"\bhorn\b"#,
        #"trombone"#, #"euphonium"#, #"\btuba\b"#, #"sousaphone"#, #"mellophone"#,
        // strings
        #"violin"#, #"viola"#, #"violoncello"#, #"\bcello\b"#, #"contrabass"#,
        #"double\s+bass"#, #"string\s+bass"#, #"upright\s+bass"#, #"\bharp\b"#,
        #"\bviolins?\s+[i1v]+\b"#, #"\bvln\b"#, #"\bvla\b"#, #"\bvc\b"#,
    ]

    static let instrument = RE(instrumentWords.joined(separator: "|"))

    /// Header lines that are never a part name.
    static let boilerplate = RE(
        #"^\s*(arr\b|arrangement|arranged|orchestrated|transcribed"# +
        #"|words?\s+and\s+music|music\s+by|lyrics?\s+by|composed"# +
        #"|copyright|all\s+rights|©|\(c\)\s|international\s+copyright"# +
        #"|this\s+arrangement|licen[cs]ed|licence|license|tres[oó]na"# +
        #"|for\s+the\s+\d{4}|duration|performance\s+time"# +
        #"|page\s+\d+|\d+\s*$)"#
    )

    /// Tempo and rehearsal text that often sits in the header band.
    static let expression = RE(
        #"^\s*((slow|fast|moderate|freely|rubato|swing|straight|ballad|groove)\b"# +
        #"|[a-z\s]*\bq\s*=\s*\d+"# +
        #"|(intro|verse|chorus|bridge|outro|vamp|tag|coda|dance\s+break|solo|tacet)\b)"#
    )

    /// Titles injected by conversion tools, which say nothing about the music.
    static let junkTitle = RE(
        #"^\s*(untitled|unnamed|document\s*\d*|new\s+document|merged\b|combined\b"# +
        #"|microsoft\s+word|word\s+document|print(out)?|output|scan(ned)?|image"# +
        #"|pdfcreator|ghostscript|acrobat|quartz|converted"# +
        #"|.*\.(pdf|docx?|pages|sib|mus|musx|mscz|xml|ps)\s*)$"#
    )

    /// "Clarinet in Bb 1" -> "Clarinet 1".
    static let transposition = RE(#"\s+in\s+[A-G][b#♭♯]?(?=\s|$)"#)
    /// Trailing page marker on a running head: "... - p.2", "... page 3".
    static let pageSuffix = RE(#"\s*[-–—,]?\s*(?:p\.?|pg\.?|page)\s*\d+\s*$"#)
    /// Separator used by running heads: "Song - Part - p.2".
    static let runningHeadSplit = RE(#"\s+[-–—]\s+"#)
    /// Filler words left behind once an instrument name is removed.
    static let filler = RE(#"\b(in|and|the|part|no|[a-g][b#]?|[0-9ivx]+)\b"#)
    static let slashSpacing = RE(#"\s*/\s*"#)
    static let trailingNumber = RE(#"\s+([0-9IVX]+)$"#, caseInsensitive: false)

    /// Printed label -> output name, matched on the whole label.
    static let defaultAliases: [String: String] = [
        "full score": "Score",
        "conductor score": "Score",
        "conductors score": "Score",
        "conductor's score": "Score",
        "condensed score": "Score",
        "piano/vocal": "Piano",
        "piano / vocal": "Piano",
        "vocal/piano": "Piano",
        "piano-vocal": "Piano",
        "piano vocal": "Piano",
        "rehearsal piano": "Piano",
        "synthesizer": "Synth",
        "synthesiser": "Synth",
        "drum set": "Drums",
        "drumset": "Drums",
        "drum kit": "Drums",
        "soprano saxophone": "Soprano_Sax",
        "alto saxophone": "Alto_Sax",
        "tenor saxophone": "Tenor_Sax",
        "baritone saxophone": "Bari_Sax",
        "baritone sax": "Bari_Sax",
        "bari sax": "Bari_Sax",
        "bass trombone": "Bass_Trombone",
        "string bass": "Upright_Bass",
        "double bass": "Upright_Bass",
    ]

    // MARK: - Cleaning

    /// Normalise a candidate label.
    ///
    /// Notation fonts map their glyphs into the Unicode private use area, so a
    /// label can arrive as "Trumpet in B\u{F062} 1" where that codepoint is a
    /// flat sign. Those glyphs mean nothing as text, so they go.
    static func clean(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping
        s = String(s.unicodeScalars.filter { !($0.value >= 0xE000 && $0.value <= 0xF8FF) })
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{2013}", with: "-")
             .replacingOccurrences(of: "\u{2014}", with: "-")
        // Readers disagree about spacing around a slash: PDFKit reports
        // "Piano/ Vocal" where others give "Piano/Vocal". It means nothing in
        // a part name, so settle it here and let one alias cover both.
        s = slashSpacing.replacing(s, with: "/")
        return s.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
    }

    /// True when a string is nothing but an instrument name.
    ///
    /// Keeps a part name from being mistaken for the song title: a part that
    /// dominates the page count would otherwise out-vote the real title and
    /// have its own pages discarded. Deliberately narrow -- "Piano" is an
    /// instrument, "Piano Man" is a song.
    static func isInstrumentName(_ text: String) -> Bool {
        var residue = instrument.replacing(text, with: " ")
        residue = transposition.replacing(residue, with: " ")
        residue = filler.replacing(residue, with: " ")
        return !residue.contains { $0.isLetter && $0.isASCII }
    }

    /// PDFKit gives no font information, so notation set as text has to be
    /// spotted by shape: real labels are mostly ASCII words.
    static func looksLikeWords(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        let ascii = letters.filter { $0.isASCII }
        guard Double(ascii.count) / Double(letters.count) >= 0.8 else { return false }
        // Require a run of at least two consecutive ASCII letters.
        var run = 0
        for ch in text {
            if ch.isLetter && ch.isASCII {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    // MARK: - Names

    /// Turn a printed label into a tidy, filename-safe part name.
    /// "Clarinet in Bb 1" -> "Clarinet1", "Alto Saxophone" -> "Alto_Sax".
    static func normalise(_ label: String, aliases: [String: String]) -> String {
        var text = clean(label)
        if let direct = aliases[text.lowercased()] { return direct }

        text = transposition.replacing(text, with: "")
        if let again = aliases[text.lowercased()] { return again }

        text = RE(#"\bsaxophone\b"#).replacing(text, with: "Sax")
        text = RE(#"\bsynthesi[sz]er\b"#).replacing(text, with: "Synth")
        text = RE(#"\bpercussion\b"#).replacing(text, with: "Perc")

        text = RE(#"[\\/]+"#).replacing(text, with: " ")
        text = clean(text)
        // Attach a trailing part number directly: "Clarinet 1" -> "Clarinet1".
        text = trailingNumber.replacing(text, with: "$1")
        text = text.replacingOccurrences(of: " ", with: "_")
        text = String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.+#-".contains($0)) })
        return text.isEmpty ? "Part" : text
    }

    /// Keep a formatted filename to a single, writable path component.
    static func safeFilename(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: "\\", with: "-")
        s = String(s.filter { ch in
            !"<>:\"|?*".contains(ch) && (ch.asciiValue.map { $0 >= 0x20 } ?? true)
        })
        s = RE(#"\s*-\s*-\s*"#).replacing(s, with: " - ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let last = s.split(separator: "/").last.map(String.init) ?? s
        return last.isEmpty ? "part.pdf" : last
    }

    /// Reduce a running head to the part name it contains.
    /// "Heads Will Roll - Alto Sax - p.2" -> "Alto Sax"
    static func stripRunningHead(_ label: String, title: String) -> String {
        var text = pageSuffix.replacing(label, with: "")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:"))
        if !title.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: title)
            if let rest = RE("^\(escaped)\\s*[-–—:]\\s*(.+)$").group(text, 1) {
                text = rest
            }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:"))
    }
}
