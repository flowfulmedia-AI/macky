import Foundation
import MackyCore

/// The user's team of agents: saved in ~/Library/Application Support/Macky/agents.json, started on their schedule
/// (or when asked), run entirely in the background (no windows, no tabs, no screen) and their results saved
/// as Google Docs. A run the Mac slept through happens as soon as it wakes, the same day.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [AgentDefinition] = []
    @Published private(set) var runningAgentIdentifiers: Set<UUID> = []

    private let settings: AppSettings
    private let apiKeyStore: OpenRouterAPIKeyStore
    private let openRouterClient: OpenRouterClient
    private let skillLibrary: SkillLibrary
    private let googleAccountManager: GoogleAccountManager
    private let webResearchService: WebResearchService
    private let fileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("agents.json")
    private var timer: Timer?
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    private static let maximumSteps = 10

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, openRouterClient: OpenRouterClient,
         skillLibrary: SkillLibrary, googleAccountManager: GoogleAccountManager, webResearchService: WebResearchService) {
        self.settings = settings
        self.apiKeyStore = apiKeyStore
        self.openRouterClient = openRouterClient
        self.skillLibrary = skillLibrary
        self.googleAccountManager = googleAccountManager
        self.webResearchService = webResearchService
        load()
    }

    func startScheduler() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDueAgents() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        runDueAgents()
    }

    func isRunning(_ identifier: UUID) -> Bool { runningAgentIdentifiers.contains(identifier) }

    func agent(named name: String) -> AgentDefinition? {
        let wanted = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func folded(_ agent: AgentDefinition) -> String { agent.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return agents.first { folded($0) == wanted } ?? agents.first { folded($0).contains(wanted) || wanted.contains(folded($0)) }
    }

    // MARK: Editing

    func upsert(_ agent: AgentDefinition) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            // Keep the history; only the settings change.
            var updated = agent
            updated.runs = agents[index].runs
            updated.lastRunAt = agents[index].lastRunAt
            agents[index] = updated
        } else {
            var created = agent
            // A new scheduled agent waits for its next time instead of running right away.
            if created.schedule.isEnabled { created.lastRunAt = Date() }
            agents.append(created)
        }
        save()
    }

    func setEnabled(_ isEnabled: Bool, for identifier: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == identifier }) else { return }
        agents[index].isEnabled = isEnabled
        save()
    }

    func delete(_ identifier: UUID) {
        stop(identifier)
        agents.removeAll { $0.id == identifier }
        save()
    }

    // MARK: Running

    private func runDueAgents() {
        let now = Date()
        for agent in agents where agent.isDue(now: now) && !isRunning(agent.id) {
            run(agent.id)
        }
    }

    /// Starts an agent in the background; `extraRequest` adds something for this run only.
    @discardableResult
    func run(_ identifier: UUID, extraRequest: String? = nil) -> Bool {
        guard let agent = agents.first(where: { $0.id == identifier }), !isRunning(identifier) else { return false }
        let run = AgentRun()
        update(identifier) { stored in
            stored.lastRunAt = run.startedAt
            stored.record(run)
        }
        runningAgentIdentifiers.insert(identifier)
        runningTasks[identifier] = Task { [weak self] in
            await self?.perform(agent, run: run, extraRequest: extraRequest)
        }
        return true
    }

    func stop(_ identifier: UUID) {
        runningTasks[identifier]?.cancel()
        runningTasks[identifier] = nil
        runningAgentIdentifiers.remove(identifier)
        update(identifier) { stored in
            if let index = stored.runs.firstIndex(where: { $0.status == .running }) {
                stored.runs[index].status = .failed
                stored.runs[index].finishedAt = Date()
                stored.runs[index].summary = "Oprit de tine."
            }
        }
    }

    private func perform(_ agent: AgentDefinition, run: AgentRun, extraRequest: String?) async {
        var finishedRun = run
        do {
            let result = try await produce(agent, extraRequest: extraRequest, run: &finishedRun)
            guard !Task.isCancelled else { return }
            if let folderIdentifier = AgentKit.driveFolderIdentifier(from: agent.driveFolder) {
                let title = AgentKit.documentTitle(agentName: agent.name, date: run.startedAt)
                finishedRun.documentLink = try await googleAccountManager.uploadGoogleDoc(
                    named: title, html: MarkdownHTML.document(title: title, markdown: result), intoFolder: folderIdentifier)
            } else {
                finishedRun.documentLink = try saveLocally(result, agentName: agent.name, date: run.startedAt)
            }
            finishedRun.status = .succeeded
            finishedRun.summary = AgentKit.summary(of: result)
        } catch {
            guard !Task.isCancelled else { return }
            finishedRun.status = .failed
            finishedRun.summary = CompanionSession.userFacingMessage(for: error)
        }
        finishedRun.finishedAt = Date()
        let completed = finishedRun
        update(agent.id) { $0.record(completed) }
        runningAgentIdentifiers.remove(agent.id)
        runningTasks[agent.id] = nil
    }

    /// The agent's own loop: its instructions and skill, plus web research when allowed. Never touches the screen.
    private func produce(_ agent: AgentDefinition, extraRequest: String?, run: inout AgentRun) async throws -> String {
        guard let apiKey = apiKeyStore.apiKey(), !apiKey.isEmpty else { throw AgentError("Lipsește cheia OpenRouter.") }
        let modelIdentifier = settings.powerfulModelIdentifier.isEmpty ? settings.fastModelIdentifier : settings.powerfulModelIdentifier
        guard !modelIdentifier.isEmpty else { throw AgentError("Alege un model în Setări → Model AI.") }

        var skillText = ""
        if !agent.skillName.isEmpty {
            guard let skill = skillLibrary.skill(named: agent.skillName) else {
                throw AgentError("Nu găsesc skill-ul „\(agent.skillName)”. Verifică Setări → Skills.")
            }
            skillText = Self.fullSkillText(skill)
        }
        let previousTitles = agent.runs.filter { $0.status == .succeeded }.prefix(5).map(\.summary)
        var messages = [
            ChatMessage(role: .system, text: AgentKit.systemPrompt(agentName: agent.name, skillName: agent.skillName, skillText: skillText,
                                                                   allowsWebResearch: agent.allowsWebResearch,
                                                                   writesDocument: true)),
            ChatMessage(role: .user, text: AgentKit.taskMessage(instructions: agent.instructions, extraRequest: extraRequest,
                                                                dateContext: FlexibleDateParser.currentDateContext(),
                                                                previousTitles: Array(previousTitles)))
        ]
        let tools: [MackyTool] = agent.allowsWebResearch ? [.webSearch, .fetchURL] : []

        for stepNumber in 1...Self.maximumSteps {
            try Task.checkCancellation()
            let requestBody = try OpenRouterRequestBuilder.makeChatCompletionBody(
                modelIdentifier: modelIdentifier,
                messages: messages,
                tools: tools,
                coordinateConvention: .imagePixels,
                maximumResponseTokens: 16_000
            )
            let response = try await openRouterClient.collectChatCompletion(requestBody: requestBody, apiKey: apiKey, purpose: .agents)
            run.costInCredits += response.usage?.costInCredits ?? 0
            if response.toolCalls.isEmpty || stepNumber == Self.maximumSteps {
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AgentError("Modelul nu a trimis niciun rezultat.") }
                return text
            }
            messages.append(ChatMessage(role: .assistant, parts: response.text.isEmpty ? [] : [.text(response.text)], toolCalls: response.toolCalls))
            for toolCall in response.toolCalls {
                let arguments = (toolCall.argumentsJSON.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let result: String
                switch MackyTool(rawValue: toolCall.name) {
                case .webSearch:
                    let search = await webResearchService.search((arguments["query"] as? String) ?? "", apiKey: apiKey)
                    run.costInCredits += search.cost ?? 0
                    result = search.text
                case .fetchURL:
                    result = await webResearchService.readableText(from: (arguments["url"] as? String) ?? "")
                default:
                    result = "This tool is not available."
                }
                messages.append(.toolResult(for: toolCall, result: result))
            }
            if stepNumber == Self.maximumSteps - 1 {
                messages.append(ChatMessage(role: .user, text: "Stop researching. Write the complete final result now."))
            }
        }
        throw AgentError("Agentul nu a terminat.")
    }

    /// The skill's SKILL.md plus the reference files next to it (examples, product pages, rules), within a size limit.
    private static func fullSkillText(_ skill: SkillDefinition) -> String {
        var text = skill.instructions
        let folder = URL(fileURLWithPath: skill.sourcePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let fileExtension = fileURL.pathExtension.lowercased()
            if ["md", "txt"].contains(fileExtension), fileURL.lastPathComponent.lowercased() != "skill.md" { files.append(fileURL) }
        }
        for fileURL in files.sorted(by: { $0.path < $1.path }) {
            guard text.count < 90_000, let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: folder.path + "/", with: "")
            text += "\n\n--- \(relativePath) ---\n" + String(content.prefix(90_000 - text.count))
        }
        return text
    }

    /// Without a Drive folder the result is a Markdown file in ~/Documents/Macky/Agenti.
    private func saveLocally(_ result: String, agentName: String, date: Date) throws -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Macky/Agenti", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent(HTMLTextExtractor.sanitizedFileName(AgentKit.documentTitle(agentName: agentName, date: date) + ".md"))
        try result.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.absoluteString
    }

    // MARK: Storage

    private func update(_ identifier: UUID, _ change: (inout AgentDefinition) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == identifier }) else { return }
        change(&agents[index])
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), var saved = try? decoder.decode([AgentDefinition].self, from: data) {
            // A run interrupted by quitting Macky is marked as such.
            for agentIndex in saved.indices {
                for runIndex in saved[agentIndex].runs.indices where saved[agentIndex].runs[runIndex].status == .running {
                    saved[agentIndex].runs[runIndex].status = .failed
                    saved[agentIndex].runs[runIndex].summary = "Întrerupt (Macky s-a închis)."
                }
            }
            agents = saved
        } else {
            agents = [Self.romeoExample]
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(agents) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    struct AgentError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The first agent, set up as asked: every morning, angles and hooks for each of Romeo Popescu's products.
    static let romeoExample = AgentDefinition(
        name: "Romeo · unghiuri și hookuri",
        instructions: """
        Fă documentul de idei de reclame pentru azi, pentru Romeo Popescu.
        Pentru fiecare produs de mai jos scrie 10 unghiuri de reclamă și 10 hookuri (prima frază din reclamă / textul de pe banner), diferite între ele și diferite de cele din zilele trecute:
        1. Interpretare Numerologică
        2. Interpretare ADN Financiar
        3. Interpretare Viața în DOI
        4. Masterclass GRATUIT – 15.10
        Structura documentului: titlu cu data, apoi câte o secțiune pe produs, cu „Unghiuri” (fiecare: nume scurt + o frază care explică ideea) și „Hookuri” (numerotate).
        Respectă vocea lui Romeo și regulile de conformitate Meta din skill.
        """,
        skillName: "macky-romeo",
        schedule: RoutineSchedule(isEnabled: true, hour: 7, minute: 0, weekdays: RoutineSchedule.everyDay),
        driveFolder: "https://drive.google.com/drive/folders/1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC"
    )
}
