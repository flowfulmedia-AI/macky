import AppKit
import AVFoundation
import ApplicationServices

enum MackyPermission: String, CaseIterable, Identifiable {
    case microphone
    case screenRecording
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microfon"
        case .screenRecording: return "Înregistrare ecran"
        case .accessibility: return "Accesibilitate"
        case .inputMonitoring: return "Monitorizare tastatură"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: return "Ca să te audă cât ții apăsată scurtătura."
        case .screenRecording: return "Ca să vadă ecranul, doar în momentul în care întrebi."
        case .accessibility: return "Ca să găsească exact butoanele și să scrie textul dictat."
        case .inputMonitoring: return "Ca să observe scurtătura ⌃⌥ din orice aplicație."
        }
    }

    var systemSettingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Tracks the four macOS privacy permissions Macky needs and asks for them one at a time,
/// always with an explanation first.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var grantedPermissions: Set<MackyPermission> = []
    /// macOS only applies Screen Recording to a process after it restarts.
    @Published private(set) var needsRestartForScreenRecording = false

    private var pollingTimer: Timer?
    private var hasRequestedScreenRecording = false

    var allPermissionsGranted: Bool { grantedPermissions.count == MackyPermission.allCases.count }
    var missingPermissions: [MackyPermission] { MackyPermission.allCases.filter { !grantedPermissions.contains($0) } }

    init() {
        refresh()
        startPolling()
    }

    func isGranted(_ permission: MackyPermission) -> Bool {
        grantedPermissions.contains(permission)
    }

    func refresh() {
        var currentlyGranted: Set<MackyPermission> = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { currentlyGranted.insert(.microphone) }
        if CGPreflightScreenCaptureAccess() { currentlyGranted.insert(.screenRecording) }
        if AXIsProcessTrusted() { currentlyGranted.insert(.accessibility) }
        if CGPreflightListenEventAccess() { currentlyGranted.insert(.inputMonitoring) }
        if currentlyGranted != grantedPermissions {
            grantedPermissions = currentlyGranted
        }
        needsRestartForScreenRecording = hasRequestedScreenRecording && !currentlyGranted.contains(.screenRecording)
    }

    func request(_ permission: MackyPermission) {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in self.refresh() }
                }
            } else {
                openSystemSettings(for: permission)
            }
        case .screenRecording:
            hasRequestedScreenRecording = true
            // Shows the system prompt the first time; afterwards only System Settings can change it.
            if !CGRequestScreenCaptureAccess() {
                openSystemSettings(for: permission)
            }
        case .accessibility:
            let promptOptionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            if !AXIsProcessTrustedWithOptions([promptOptionKey: true] as CFDictionary) {
                openSystemSettings(for: permission)
            }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() {
                openSystemSettings(for: permission)
            }
        }
        refresh()
    }

    func openSystemSettings(for permission: MackyPermission) {
        NSWorkspace.shared.open(permission.systemSettingsURL)
    }

    /// Polls cheaply so the panel updates as soon as a permission is granted in System Settings.
    private func startPolling() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainThread.run {
                self?.refresh()
            }
        }
        pollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func relaunchApplication() {
        let applicationPath = Bundle.main.bundlePath
        let relaunchProcess = Process()
        relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunchProcess.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(applicationPath)\""]
        try? relaunchProcess.run()
        MackyWindowGuard.shared.userRequestedQuit = true
        NSApp.terminate(nil)
    }
}
