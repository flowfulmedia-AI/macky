import Foundation
import MackyCore

/// The list of OpenRouter models that accept images, cached on disk so Settings opens instantly.
@MainActor
final class ModelCatalogStore: ObservableObject {
    @Published private(set) var visionModels: [ModelSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadErrorMessage: String?

    private let openRouterClient: OpenRouterClient
    private let cacheFileURL: URL

    init(openRouterClient: OpenRouterClient) {
        self.openRouterClient = openRouterClient
        cacheFileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("models-cache.json")
        loadCachedModels()
    }

    func model(withIdentifier identifier: String) -> ModelSummary? {
        visionModels.first { $0.id == identifier }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let allModels = try await openRouterClient.fetchModels()
            visionModels = allModels
                .filter(\.acceptsImages)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            loadErrorMessage = nil
            saveCache()
        } catch {
            loadErrorMessage = "Nu am putut încărca lista de modele: \(error.localizedDescription)"
        }
    }

    private func loadCachedModels() {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let cachedModels = try? JSONDecoder().decode([ModelSummary].self, from: data) else { return }
        visionModels = cachedModels
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(visionModels) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }
}

enum ApplicationDirectories {
    /// ~/Library/Application Support/Macky, created on first use.
    static var applicationSupportDirectory: URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = baseDirectory.appendingPathComponent("Macky", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
