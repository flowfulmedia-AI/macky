import Foundation

/// A model from OpenRouter's `GET /api/v1/models` list.
public struct ModelSummary: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var acceptsImages: Bool
    public var supportsToolCalling: Bool
    /// USD per one million input / output tokens.
    public var inputPricePerMillionTokens: Double?
    public var outputPricePerMillionTokens: Double?
    public var createdTimestamp: Int

    public init(id: String, name: String, acceptsImages: Bool, supportsToolCalling: Bool,
                inputPricePerMillionTokens: Double?, outputPricePerMillionTokens: Double?, createdTimestamp: Int) {
        self.id = id
        self.name = name
        self.acceptsImages = acceptsImages
        self.supportsToolCalling = supportsToolCalling
        self.inputPricePerMillionTokens = inputPricePerMillionTokens
        self.outputPricePerMillionTokens = outputPricePerMillionTokens
        self.createdTimestamp = createdTimestamp
    }

    public var isFree: Bool { id.hasSuffix(":free") || (inputPricePerMillionTokens == 0 && outputPricePerMillionTokens == 0) }

    public var priceDescription: String {
        if isFree { return "gratuit" }
        guard let inputPricePerMillionTokens, let outputPricePerMillionTokens else { return "preț necunoscut" }
        return String(format: "$%.2f / $%.2f per 1M tokeni", inputPricePerMillionTokens, outputPricePerMillionTokens)
    }
}

public enum ModelCatalog {
    public static func parseModelsResponse(_ data: Data) throws -> [ModelSummary] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            throw OpenRouterAPIError(httpStatusCode: nil, message: "Lista de modele are un format neașteptat.")
        }
        return entries.compactMap { entry in
            guard let identifier = entry["id"] as? String else { return nil }
            let architecture = entry["architecture"] as? [String: Any]
            let inputModalities = architecture?["input_modalities"] as? [String] ?? []
            let legacyModality = architecture?["modality"] as? String ?? ""
            let supportedParameters = entry["supported_parameters"] as? [String] ?? []
            let pricing = entry["pricing"] as? [String: Any]
            return ModelSummary(
                id: identifier,
                name: entry["name"] as? String ?? identifier,
                acceptsImages: inputModalities.contains("image") || legacyModality.contains("image->"),
                supportsToolCalling: supportedParameters.contains("tools"),
                inputPricePerMillionTokens: OpenRouterStreamDecoder.doubleValue(pricing?["prompt"]).map { $0 * 1_000_000 },
                outputPricePerMillionTokens: OpenRouterStreamDecoder.doubleValue(pricing?["completion"]).map { $0 * 1_000_000 },
                createdTimestamp: OpenRouterStreamDecoder.integerValue(entry["created"]) ?? 0
            )
        }
    }

    /// Picks the newest vision model whose identifier contains every fragment in `requiredFragments`
    /// and none of `excludedFragments`. Used to choose sensible defaults without hard-coding
    /// identifiers that change every few months.
    public static func newestModel(in models: [ModelSummary], containingAll requiredFragments: [String], excluding excludedFragments: [String] = defaultExcludedFragments) -> ModelSummary? {
        models
            .filter { model in
                let lowercasedIdentifier = model.id.lowercased()
                return model.acceptsImages
                    && requiredFragments.allSatisfy { lowercasedIdentifier.contains($0.lowercased()) }
                    && !excludedFragments.contains { lowercasedIdentifier.contains($0.lowercased()) }
            }
            .max { $0.createdTimestamp < $1.createdTimestamp }
    }

    public static let defaultExcludedFragments = ["image", "audio", "tts", "lite", ":free", ":thinking", "online", "extended"]

    public static func defaultFastModel(in models: [ModelSummary]) -> ModelSummary? {
        newestModel(in: models, containingAll: ["google/gemini", "flash"])
            ?? newestModel(in: models, containingAll: ["anthropic/claude", "haiku"])
            ?? newestModel(in: models, containingAll: ["openai/gpt", "mini"])
    }

    public static func defaultPowerfulModel(in models: [ModelSummary]) -> ModelSummary? {
        newestModel(in: models, containingAll: ["anthropic/claude", "sonnet"])
            ?? newestModel(in: models, containingAll: ["google/gemini", "pro"])
            ?? newestModel(in: models, containingAll: ["openai/gpt"])
    }
}
