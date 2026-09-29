import Foundation

/// Splits streamed text into complete sentences so speech can start before the whole answer arrives.
public struct SentenceSegmenter {
    private static let sentenceEndingCharacters: Set<Character> = [".", "!", "?", "…", ";"]
    /// Words that end with a period but do not end a sentence (compared lowercased, without the period).
    private static let abbreviations: Set<String> = ["ex", "dr", "nr", "dl", "dna", "vs", "mr", "mrs", "e.g", "i.e", "fig", "pag", "art", "ing", "prof"]
    private static let minimumSentenceLength = 2

    private var pendingText = ""

    public init() {}

    public mutating func append(_ text: String) -> [String] {
        pendingText += text
        var completedSentences: [String] = []
        var sentenceStart = pendingText.startIndex
        var index = pendingText.startIndex

        while index < pendingText.endIndex {
            let character = pendingText[index]
            let nextIndex = pendingText.index(after: index)

            if character == "\n" {
                appendSentence(from: sentenceStart, to: index, into: &completedSentences)
                sentenceStart = nextIndex
            } else if Self.sentenceEndingCharacters.contains(character) {
                // Only a boundary when followed by whitespace; "3.5" or "fișier.txt" must not split.
                // If this is the last character we wait for more text to decide.
                guard nextIndex < pendingText.endIndex else { break }
                if pendingText[nextIndex].isWhitespace && !endsWithAbbreviation(pendingText[sentenceStart..<index]) {
                    appendSentence(from: sentenceStart, to: nextIndex, into: &completedSentences)
                    sentenceStart = nextIndex
                }
            }
            index = nextIndex
        }

        pendingText = String(pendingText[sentenceStart...])
        return completedSentences
    }

    public mutating func flush() -> String? {
        let remainingText = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        return remainingText.count >= Self.minimumSentenceLength ? remainingText : nil
    }

    private func appendSentence(from start: String.Index, to end: String.Index, into sentences: inout [String]) {
        let sentence = pendingText[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence.count >= Self.minimumSentenceLength {
            sentences.append(sentence)
        }
    }

    private func endsWithAbbreviation(_ textBeforePeriod: Substring) -> Bool {
        guard let lastWord = textBeforePeriod.split(whereSeparator: { $0.isWhitespace }).last else { return false }
        let normalizedWord = lastWord.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'"))
        if Self.abbreviations.contains(normalizedWord) { return true }
        // A single capital letter is an initial ("A. Popescu"), not the end of a sentence.
        return lastWord.count == 1 && lastWord.first?.isUppercase == true
    }
}

/// Makes model output suitable for a speech synthesizer and a small text bubble:
/// removes Markdown symbols, links and code formatting that would otherwise be read aloud.
public enum SpeechTextCleaner {
    public static func cleanForSpeech(_ text: String) -> String {
        var cleanedText = text
        // [link text](https://...) -> link text
        cleanedText = cleanedText.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Bare URLs are not useful spoken.
        cleanedText = cleanedText.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Headings and bullet markers at the start of a line.
        cleanedText = cleanedText.replacingOccurrences(of: #"(?m)^\s*(#{1,6}|[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        for markdownSymbol in ["**", "__", "`", "~~"] {
            cleanedText = cleanedText.replacingOccurrences(of: markdownSymbol, with: "")
        }
        // Single emphasis asterisks, e.g. *word*.
        cleanedText = cleanedText.replacingOccurrences(of: #"(?<!\w)\*(\S[^*]*)\*(?!\w)"#, with: "$1", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
