import Foundation

/// Whisper, given silence or noise, "hears" the closing lines of the videos it was trained on
/// ("Vă mulțumim pentru vizionare", "Abonați-vă"). Such a transcript means nothing was said.
public enum TranscriptFilter {
    static let phantomPhrases = [
        "sa va multumim de vizionare", "va multumim pentru vizionare", "va multumim de vizionare",
        "multumim pentru vizionare", "multumim de vizionare", "multumesc pentru vizionare", "multumesc de vizionare",
        "va multumesc pentru vizionare", "va multumesc pentru atentie", "multumesc pentru atentie",
        "nu uitati sa va abonati", "abonati-va la canal", "abonati va la canal", "abonati-va", "abonati va",
        "dati like si subscribe", "like si subscribe", "subtitrarea realizata de", "subtitrari realizate de",
        "subtitrare realizata de", "subtitrare", "traducerea si adaptarea", "pe curand", "la revedere",
        "thanks for watching", "thank you for watching", "please subscribe", "subscribe to my channel",
        "thank you", "multumesc", "multumim"
    ]

    /// True when the transcript is only one or more of those phantom phrases.
    public static func isPhantom(_ transcript: String) -> Bool {
        var text = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ro"))
        text = String(text.unicodeScalars.map { CharacterSet.letters.contains($0) || $0 == "-" ? Character($0) : " " })
        text = text.split(separator: " ").joined(separator: " ")
        guard !text.isEmpty else { return true }
        for phrase in phantomPhrases {
            text = text.replacingOccurrences(of: phrase, with: " ")
        }
        let remainingLetters = text.filter(\.isLetter).count
        return remainingLetters < 3
    }
}
