import Foundation

/// Scores how well an on-screen element's texts (title, description, value) match the name
/// the model asked for. Case and diacritics are ignored ("Salvează" matches "salveaza").
public enum ElementLabelMatcher {
    public static let exactMatchScore = 3
    public static let startsWithScore = 2
    public static let containsScore = 1

    public static func score(elementTexts: [String], wantedLabel: String) -> Int? {
        let wanted = normalize(wantedLabel)
        guard !wanted.isEmpty else { return nil }
        var bestScore: Int?
        for elementText in elementTexts {
            let candidate = normalize(elementText)
            guard !candidate.isEmpty else { continue }
            let candidateScore: Int?
            if candidate == wanted {
                candidateScore = exactMatchScore
            } else if candidate.hasPrefix(wanted) || wanted.hasPrefix(candidate) && candidate.count >= 3 {
                candidateScore = startsWithScore
            } else if candidate.contains(wanted) {
                candidateScore = containsScore
            } else {
                candidateScore = nil
            }
            if let candidateScore, candidateScore > (bestScore ?? 0) {
                bestScore = candidateScore
            }
        }
        return bestScore
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
