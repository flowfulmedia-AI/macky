import AppKit
import Combine
import MackyCore
import SwiftUI

/// Creates every long-lived object once and wires them together.
@MainActor
final class AppEnvironment {
    let settings = AppSettings()
    let apiKeyStore = OpenRouterAPIKeyStore()
    let spotifyCredentialsStore = SpotifyCredentialsStore()
    let permissions = PermissionsManager()
    let openRouterClient = OpenRouterClient()
    let modelCatalogStore: ModelCatalogStore
    let overlayController = CompanionOverlayController()
    let drawingOverlayController = DrawingOverlayController()
    let companionSession: CompanionSession
    let memoryManager: MemoryManager
    let historyStore: HistoryStore
    let skillLibrary: SkillLibrary
    let googleAccountManager = GoogleAccountManager()
    let routineStore = RoutineStore()
    let mcpConnectionStore = MCPConnectionStore()
    let zoomMeetingsManager: ZoomMeetingsManager
    let usageStore: UsageStore
    let agentStore: AgentStore
    let hotkeyMonitor: GlobalHotkeyMonitor
    let windowCoordinator = WindowCoordinator()
    private(set) var menuBarController: MenuBarController!
    private(set) var notchPanelController: NotchPanelController!

    private var cancellables: Set<AnyCancellable> = []
    private var hotkeyRetryTimer: Timer?

    init() {
        modelCatalogStore = ModelCatalogStore(openRouterClient: openRouterClient)
        let usageStore = UsageStore(apiKeyStore: apiKeyStore, openRouterClient: openRouterClient)
        self.usageStore = usageStore
        // Every request's cost goes into the usage ledger, with what it was for.
        openRouterClient.onUsage = { usage, purpose in
            Task { @MainActor in usageStore.record(usage, purpose: purpose) }
        }
        memoryManager = MemoryManager(settings: settings, apiKeyStore: apiKeyStore, openRouterClient: openRouterClient)
        historyStore = HistoryStore(settings: settings)
        skillLibrary = SkillLibrary(settings: settings)
        zoomMeetingsManager = ZoomMeetingsManager(settings: settings, apiKeyStore: apiKeyStore, openRouterClient: openRouterClient,
                                                  googleAccountManager: googleAccountManager)
        companionSession = CompanionSession(
            settings: settings,
            apiKeyStore: apiKeyStore,
            modelCatalogStore: modelCatalogStore,
            overlayController: overlayController,
            drawingOverlayController: drawingOverlayController,
            spotifyCredentialsStore: spotifyCredentialsStore,
            openRouterClient: openRouterClient,
            memoryManager: memoryManager,
            historyStore: historyStore,
            skillLibrary: skillLibrary,
            googleAccountManager: googleAccountManager,
            routineStore: routineStore,
            mcpConnectionStore: mcpConnectionStore,
            zoomMeetingsManager: zoomMeetingsManager
        )
        agentStore = AgentStore(settings: settings, apiKeyStore: apiKeyStore, openRouterClient: openRouterClient,
                                skillLibrary: skillLibrary, googleAccountManager: googleAccountManager,
                                webResearchService: companionSession.backgroundAgentManager.webResearchService)
        companionSession.agentStore = agentStore
        hotkeyMonitor = GlobalHotkeyMonitor(talkCombination: settings.talkCombination, dictationCombination: settings.dictationCombination)
        menuBarController = MenuBarController { [unowned self] in self.makePanelContent() }
        notchPanelController = NotchPanelController(session: companionSession) { [unowned self] in self.makePanelContent() }
    }

    func start() {
        overlayController.start()
        applyPanelPlacement()

        hotkeyMonitor.onHotkeyEvent = { [weak companionSession] hotkeyEvent in
            // The event tap runs on the main run loop, so this is already the main thread.
            MainActor.assumeIsolated {
                companionSession?.handle(hotkeyEvent)
            }
        }
        startHotkeyMonitorWhenPermitted()

        Publishers.CombineLatest(settings.$talkCombination, settings.$dictationCombination)
            .dropFirst()
            .sink { [weak self] talkCombination, dictationCombination in
                self?.hotkeyMonitor.updateCombinations(talkCombination: talkCombination, dictationCombination: dictationCombination)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$notchPanelEnabled, settings.$showMenuBarIcon)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyPanelPlacement() }
            .store(in: &cancellables)

        companionSession.prepareTranscriber()
        memoryManager.start()
        skillLibrary.reload()
        routineStore.onRoutineDue = { [weak companionSession] routine in
            companionSession?.startScheduledRoutine(routine) ?? false
        }
        routineStore.startScheduler()
        agentStore.startScheduler()
        Task { await mcpConnectionStore.refreshAll() }
        zoomMeetingsManager.start()
        usageStore.start()

        Task {
            await modelCatalogStore.refresh()
            settings.applyDefaultModelsIfNeeded(from: modelCatalogStore.visionModels)
        }

        // First run: show the checklist right away.
        if !apiKeyStore.hasAPIKey || !permissions.allPermissionsGranted {
            showPanel()
        }
    }

    func stop() {
        hotkeyMonitor.stop()
        companionSession.stopEverything()
    }

    /// The notch (or menu bar) panel: a sidebar of Macky's sections, with the quick-question panel as the first one.
    private func makePanelContent() -> AnyView {
        let suggestions = currentSuggestions()
        let quickPanel = CompanionPanelView(
            session: companionSession,
            settings: settings,
            permissions: permissions,
            apiKeyStore: apiKeyStore,
            modelCatalogStore: modelCatalogStore,
            agentManager: companionSession.backgroundAgentManager,
            usageStore: usageStore,
            suggestions: suggestions,
            openHome: { [unowned self] in self.openHome() },
            openSettings: { [unowned self] in self.openSettings() },
            openCalibration: { [unowned self] in self.openCalibration() },
            openMemory: { [unowned self] in self.openMemory() },
            openHistory: { [unowned self] in self.openHistory() }
        )
        return AnyView(HomeView(
            session: companionSession,
            settings: settings,
            usageStore: usageStore,
            agentManager: companionSession.backgroundAgentManager,
            zoomMeetingsManager: zoomMeetingsManager,
            memoryManager: memoryManager,
            historyStore: historyStore,
            routineStore: routineStore,
            agentStore: agentStore,
            skillLibrary: skillLibrary,
            googleAccountManager: googleAccountManager,
            suggestions: suggestions,
            openSettings: { [unowned self] in self.openSettings() },
            compact: true,
            homeContent: AnyView(quickPanel)
        ))
    }

    /// Starter ideas that fit what is connected and the time of day.
    private func currentSuggestions() -> [SuggestionCatalog.Suggestion] {
        SuggestionCatalog.suggestions(
            hasGoogle: googleAccountManager.isConnected,
            hasTaskApp: mcpConnectionStore.toolNamesByServer.values.contains { names in names.contains { $0.lowercased().contains("task") } },
            hasZoom: zoomMeetingsManager.hasCredentials,
            hour: Calendar.current.component(.hour, from: Date())
        )
    }

    private func openHome() {
        hidePanels()
        _ = windowCoordinator.showWindow(identifier: "home", title: "Macky", size: NSSize(width: 1080, height: 720), transparentTitleBar: true) {
            HomeView(
                session: companionSession,
                settings: settings,
                usageStore: usageStore,
                agentManager: companionSession.backgroundAgentManager,
                zoomMeetingsManager: zoomMeetingsManager,
                memoryManager: memoryManager,
                historyStore: historyStore,
                routineStore: routineStore,
                agentStore: agentStore,
                skillLibrary: skillLibrary,
                googleAccountManager: googleAccountManager,
                suggestions: currentSuggestions(),
                openSettings: { [unowned self] in self.openSettings() }
            )
        }
    }

    /// Notch panel, menu bar icon, or both. Without a notch panel the icon is always shown,
    /// so Macky can never become unreachable.
    private func applyPanelPlacement() {
        if settings.notchPanelEnabled {
            notchPanelController.start()
        } else {
            notchPanelController.stop()
        }
        if settings.showMenuBarIcon || !settings.notchPanelEnabled {
            menuBarController.install()
        } else {
            menuBarController.uninstall()
        }
    }

    private func showPanel() {
        if settings.notchPanelEnabled {
            notchPanelController.expand(pinned: true)
        } else {
            menuBarController.showPanel()
        }
    }

    private func hidePanels() {
        menuBarController.hidePanel()
        notchPanelController.collapse()
    }

    /// The keyboard tap only works once Input Monitoring is granted; keep retrying quietly until then.
    private func startHotkeyMonitorWhenPermitted() {
        if hotkeyMonitor.start() { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.hotkeyMonitor.start() {
                    timer.invalidate()
                    self.hotkeyRetryTimer = nil
                }
            }
        }
        hotkeyRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func openSettings() {
        hidePanels()
        _ = windowCoordinator.showWindow(identifier: "settings", title: "Setări Macky", size: NSSize(width: 980, height: 760)) {
            SettingsView(
                settings: settings,
                apiKeyStore: apiKeyStore,
                modelCatalogStore: modelCatalogStore,
                session: companionSession,
                spotifyCredentialsStore: spotifyCredentialsStore,
                openRouterClient: openRouterClient,
                skillLibrary: skillLibrary,
                googleAccountManager: googleAccountManager,
                routineStore: routineStore,
                mcpConnectionStore: mcpConnectionStore,
                zoomMeetingsManager: zoomMeetingsManager,
                whatsAppController: companionSession.whatsAppController,
                memoryManager: memoryManager,
                openMemory: { [unowned self] in self.openMemory() },
                openHistory: { [unowned self] in self.openHistory() },
                openCalibration: { [unowned self] in self.openCalibration() }
            )
        }
    }

    private func openMemory() {
        hidePanels()
        _ = windowCoordinator.showWindow(identifier: "memory", title: "Memoria lui Macky", size: NSSize(width: 860, height: 680), transparentTitleBar: true) {
            MemoryView(memoryManager: memoryManager, settings: settings)
                .frame(minWidth: 640, minHeight: 480)
        }
    }

    private func openHistory() {
        hidePanels()
        _ = windowCoordinator.showWindow(identifier: "history", title: "Istoric Macky", size: NSSize(width: 760, height: 640)) {
            HistoryView(historyStore: historyStore, settings: settings)
        }
    }

    private lazy var calibrationRunner = CalibrationRunner(
        settings: settings,
        apiKeyStore: apiKeyStore,
        modelCatalogStore: modelCatalogStore,
        openRouterClient: openRouterClient
    )

    private func openCalibration() {
        hidePanels()
        let calibrationRunner = self.calibrationRunner
        let window = windowCoordinator.showWindow(identifier: "calibration", title: "Calibrare Macky", size: NSSize(width: 980, height: 700)) {
            CalibrationView(runner: calibrationRunner, settings: settings)
        }
        calibrationRunner.window = window
    }
}
