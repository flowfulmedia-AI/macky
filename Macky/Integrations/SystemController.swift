import AppKit
import MackyCore

/// Result of a direct integration (system, calendar, notes, windows).
struct IntegrationOutcome {
    var succeeded: Bool
    /// Shown to the user and returned to the model.
    var message: String
}

/// Volume, brightness, dark mode, lock screen, display sleep — without the model or the screen.
@MainActor
final class SystemController {
    private let executor: ScreenActionExecutor
    private static let volumeStep = 12

    init(executor: ScreenActionExecutor) {
        self.executor = executor
    }

    func perform(_ command: SystemCommand) async -> IntegrationOutcome {
        switch command {
        case .setVolume(let percent):
            return await setVolume(percent)
        case .volumeUp:
            return await setVolume(min(100, (await currentVolume() ?? 50) + Self.volumeStep))
        case .volumeDown:
            return await setVolume(max(0, (await currentVolume() ?? 50) - Self.volumeStep))
        case .mute:
            return await runScript("set volume with output muted", successMessage: "Sunet oprit.")
        case .unmute:
            return await runScript("set volume without output muted", successMessage: "Sunet pornit.")
        case .brightnessUp:
            // Two presses of the brightness key, like tapping F2 twice.
            executor.pressAuxiliaryKey(code: 2)
            executor.pressAuxiliaryKey(code: 2)
            return IntegrationOutcome(succeeded: true, message: "Luminozitate mai mare.")
        case .brightnessDown:
            executor.pressAuxiliaryKey(code: 3)
            executor.pressAuxiliaryKey(code: 3)
            return IntegrationOutcome(succeeded: true, message: "Luminozitate mai mică.")
        case .darkMode(let enabled):
            let value = enabled.map { $0 ? "true" : "false" } ?? "not dark mode"
            return await runScript(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)",
                successMessage: command.userFacingDescription + ".",
                permissionHint: "System Events"
            )
        case .lockScreen:
            // ⌃⌘Q is macOS's own "Lock Screen" shortcut.
            executor.press(KeyCombination(keyCode: 12, modifiers: [.control, .command], displayName: "⌃⌘Q"))
            return IntegrationOutcome(succeeded: true, message: "Ecran blocat.")
        case .sleepDisplay:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            do {
                try process.run()
                return IntegrationOutcome(succeeded: true, message: "Ecran stins.")
            } catch {
                return IntegrationOutcome(succeeded: false, message: "Nu am putut stinge ecranul.")
            }
        }
    }

    private func setVolume(_ percent: Int) async -> IntegrationOutcome {
        await runScript("set volume without output muted\nset volume output volume \(percent)", successMessage: "Volum \(percent)%.")
    }

    private func currentVolume() async -> Int? {
        let result = await executor.runAppleScript("output volume of (get volume settings)")
        return result.succeeded ? Int(result.output) : nil
    }

    private func runScript(_ script: String, successMessage: String, permissionHint: String? = nil) async -> IntegrationOutcome {
        let result = await executor.runAppleScript(script)
        if result.succeeded { return IntegrationOutcome(succeeded: true, message: successMessage) }
        if let permissionHint, result.output.contains("-1743") || result.output.lowercased().contains("not authorized") {
            return IntegrationOutcome(succeeded: false, message: "Macky nu are voie să controleze \(permissionHint). Permite-l în System Settings → Privacy & Security → Automation.")
        }
        return IntegrationOutcome(succeeded: false, message: "Nu a mers: \(result.output)")
    }
}

/// Creates notes in Apple Notes through AppleScript.
@MainActor
final class NotesController {
    private let executor: ScreenActionExecutor

    init(executor: ScreenActionExecutor) {
        self.executor = executor
    }

    func createNote(title: String, body: String) async -> IntegrationOutcome {
        // Notes stores HTML; the first line becomes the note's title.
        let htmlBody = "<h1>\(Self.escapeHTML(title))</h1>" + body
            .components(separatedBy: .newlines)
            .map { "<div>\($0.isEmpty ? "<br>" : Self.escapeHTML($0))</div>" }
            .joined()
        let script = "tell application \"Notes\" to make new note with properties {body:\(SpotifyHelpers.appleScriptString(htmlBody))}"
        let result = await executor.runAppleScript(script)
        if result.succeeded {
            return IntegrationOutcome(succeeded: true, message: "Am salvat notița „\(title)” în Notes.")
        }
        if result.output.contains("-1743") {
            return IntegrationOutcome(succeeded: false, message: "Macky nu are voie să folosească Notes. Permite-l în System Settings → Privacy & Security → Automation.")
        }
        return IntegrationOutcome(succeeded: false, message: "Nu am putut crea notița: \(result.output)")
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Moves and resizes app windows through Accessibility.
@MainActor
final class WindowArranger {
    private let executor: ScreenActionExecutor

    init(executor: ScreenActionExecutor) {
        self.executor = executor
    }

    func arrange(applicationName: String?, layout: WindowLayout) async -> IntegrationOutcome {
        guard AXIsProcessTrusted() else {
            return IntegrationOutcome(succeeded: false, message: "Macky are nevoie de permisiunea Accessibility ca să mute ferestre.")
        }
        var application = Self.runningApplication(named: applicationName)
        if application == nil, let applicationName {
            // Not open yet: open it, then arrange its first window.
            guard await executor.openApplication(named: applicationName) else {
                return IntegrationOutcome(succeeded: false, message: "Nu găsesc aplicația \(applicationName).")
            }
            for _ in 0..<20 where application == nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
                application = Self.runningApplication(named: applicationName)
            }
        }
        guard let application else {
            return IntegrationOutcome(succeeded: false, message: "Nu găsesc fereastra.")
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.5)
        var window: AXUIElement?
        for _ in 0..<15 where window == nil {
            window = Self.frontWindow(of: applicationElement)
            if window == nil { try? await Task.sleep(nanoseconds: 150_000_000) }
        }
        guard let window else {
            return IntegrationOutcome(succeeded: false, message: "\(application.localizedName ?? "Aplicația") nu are nicio fereastră deschisă.")
        }

        // The window goes on the screen it is on now (or the main screen).
        let primaryScreenHeight = NSScreen.primaryScreenHeight
        let currentCenter = Self.frame(of: window).map {
            ScreenGeometry.appKitGlobalPoint(fromQuartzGlobalPoint: CGPoint(x: $0.midX, y: $0.midY), primaryScreenHeight: primaryScreenHeight)
        }
        let screen = NSScreen.screens.first { screen in currentCenter.map { screen.frame.contains($0) } ?? false } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return IntegrationOutcome(succeeded: false, message: "Nu găsesc ecranul.")
        }
        let targetFrame = layout.frame(in: visibleFrame)
        var quartzOrigin = CGPoint(x: targetFrame.minX, y: primaryScreenHeight - targetFrame.maxY)
        var targetSize = targetFrame.size

        // Position, size, position again: some apps clamp the size to the old position's screen.
        if let positionValue = AXValueCreate(.cgPoint, &quartzOrigin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &targetSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let positionValue = AXValueCreate(.cgPoint, &quartzOrigin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        application.activate()
        return IntegrationOutcome(succeeded: true, message: "\(application.localizedName ?? "Fereastra") \(layout.displayName).")
    }

    private static func runningApplication(named applicationName: String?) -> NSRunningApplication? {
        guard let applicationName, !applicationName.isEmpty else { return NSWorkspace.shared.frontmostApplication }
        let wantedName = SpotifyCommandMatcher.fold(applicationName)
        let regularApplications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return regularApplications.first { SpotifyCommandMatcher.fold($0.localizedName ?? "") == wantedName }
            ?? regularApplications.first { SpotifyCommandMatcher.fold($0.localizedName ?? "").contains(wantedName) }
    }

    private static func frontWindow(of applicationElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(applicationElement, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AnyObject], let firstWindow = windows.first,
           CFGetTypeID(firstWindow) == AXUIElementGetTypeID() {
            return (firstWindow as! AXUIElement)
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
