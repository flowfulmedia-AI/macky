import Foundation
import NaturalLanguage

/// Turns text into meaning vectors with Apple's on-device language model, so "chitanțe" can find a memory
/// about "facturi". Runs entirely on the Mac and costs nothing. When the Romanian model is not available,
/// every method returns nil and memory search uses keywords only.
actor EmbeddingService {
    private var embedding: NLContextualEmbedding?
    private var hasTriedLoading = false
    private let language = NLLanguage.romanian

    /// Loads the model, downloading Apple's assets the first time. Returns whether vectors are available.
    func prepare() async -> Bool {
        if embedding != nil { return true }
        guard !hasTriedLoading else { return false }
        hasTriedLoading = true
        guard let candidate = NLContextualEmbedding(language: language) else { return false }
        if !candidate.hasAvailableAssets {
            let assetsResult: NLContextualEmbedding.AssetsResult = await withCheckedContinuation { continuation in
                candidate.requestAssets { result, _ in continuation.resume(returning: result) }
            }
            guard assetsResult == .available else { return false }
        }
        do {
            try candidate.load()
        } catch {
            return false
        }
        embedding = candidate
        return true
    }

    /// Mean of the token vectors: a simple, solid sentence vector.
    func vector(for text: String) -> [Float]? {
        guard let embedding else { return nil }
        let input = String(text.prefix(800))
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = try? embedding.embeddingResult(for: input, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { tokenVector, _ in
            if tokenVector.count == sum.count {
                for index in sum.indices { sum[index] += tokenVector[index] }
                tokenCount += 1
            }
            return true
        }
        guard tokenCount > 0 else { return nil }
        return sum.map { Float($0 / Double(tokenCount)) }
    }
}
