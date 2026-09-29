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
    let hotkeyMonitor: GlobalHotkeyMonitor
    let windowCoordinator = WindowCoordinator()
    private(set) var menuBarController: MenuBarController!
    private(set) var notchPanelController: NotchPanelController!

    private var cancellables: Set<AnyCancellable> = []
    private var hotkeyRetryTimer: Timer?

    init() {
        modelCatalogStore = ModelCatalogStore(openRouterClient: openRouterClient)
        companionSession = CompanionSession(
            settings: settings,
            apiKeyStore: apiKeyStore,
            modelCatalogStore: modelCatalogStore,
            overlayController: overlayController,
            drawingOverlayController: drawingOverlayController,
            spotifyCredentialsStore: spotifyCredentialsStore,
            openRouterClient: openRouterClient
        )
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

    private func makePanelContent() -> AnyView {
        AnyView(CompanionPanelView(
            session: companionSession,
            settings: settings,
            permissions: permissions,
            apiKeyStore: apiKeyStore,
            modelCatalogStore: modelCatalogStore,
            openSettings: { [unowned self] in self.openSettings() },
            openCalibration: { [unowned self] in self.openCalibration() }
        ))
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
        _ = windowCoordinator.showWindow(identifier: "settings", title: "Setări Macky", size: NSSize(width: 680, height: 720)) {
            SettingsView(
                settings: settings,
                apiKeyStore: apiKeyStore,
                modelCatalogStore: modelCatalogStore,
                session: companionSession,
                spotifyCredentialsStore: spotifyCredentialsStore,
                openRouterClient: openRouterClient
            )
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
