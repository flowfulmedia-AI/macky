import AppKit
import MackyCore

/// Performs clicks, typing and key presses on behalf of the user by posting synthetic
/// input events. Needs the Accessibility permission. Macky's overlay ignores the mouse,
/// so clicks land on whatever app is underneath.
@MainActor
final class ScreenActionExecutor {
    private let textInserter: DictationTextInserter

    init(textInserter: DictationTextInserter) {
        self.textInserter = textInserter
    }

    func click(atAppKitGlobalPoint point: CGPoint, kind: ClickKind) async {
        let quartzPoint = ScreenGeometry.quartzGlobalPoint(fromAppKitGlobalPoint: point, primaryScreenHeight: NSScreen.primaryScreenHeight)
        let eventSource = CGEventSource(stateID: .hidSystemState)

        // Move there first so hover states (menus, toolbars) react like for a real mouse.
        CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 80_000_000)

        switch kind {
        case .left:
            postClick(at: quartzPoint, button: .left, clickCount: 1, eventSource: eventSource)
        case .double:
            postClick(at: quartzPoint, button: .left, clickCount: 1, eventSource: eventSource)
            try? await Task.sleep(nanoseconds: 60_000_000)
            postClick(at: quartzPoint, button: .left, clickCount: 2, eventSource: eventSource)
        case .right:
            postClick(at: quartzPoint, button: .right, clickCount: 1, eventSource: eventSource)
        }
    }

    func type(_ text: String, pressEnterAfterwards: Bool) async {
        textInserter.insert(text)
        if pressEnterAfterwards {
            // Let the paste land before submitting.
            try? await Task.sleep(nanoseconds: 350_000_000)
            press(KeyCombination(keyCode: 36, modifiers: [], displayName: "Enter"))
        }
    }

    func press(_ combination: KeyCombination) {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let flags = Self.eventFlags(for: combination.modifiers)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: combination.keyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: combination.keyCode, keyDown: false)
        keyDownEvent?.flags = flags
        keyUpEvent?.flags = flags
        keyDownEvent?.post(tap: .cgAnnotatedSessionEventTap)
        keyUpEvent?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Launches or brings forward an app by name. Returns false when no such app is installed.
    func openApplication(named name: String) async -> Bool {
        guard let applicationURL = Self.findApplication(named: name) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    /// Opens a web page or app link (spotify:, mailto:, ...). Spaces in search terms are encoded.
    func openURL(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmedText) ?? URL(string: trimmedText.replacingOccurrences(of: " ", with: "%20"))
        guard let url, url.scheme != nil else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func findApplication(named name: String) -> URL? {
        let wantedName = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        if let runningApplication = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == wantedName }),
           let bundleURL = runningApplication.bundleURL {
            return bundleURL
        }

        let searchDirectories = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        var partialMatch: URL?
        for directory in searchDirectories {
            guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for fileName in fileNames where fileName.hasSuffix(".app") {
                let applicationName = String(fileName.dropLast(4)).lowercased()
                let applicationURL = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
                if applicationName == wantedName { return applicationURL }
                if partialMatch == nil && (applicationName.contains(wantedName) || wantedName.contains(applicationName)) {
                    partialMatch = applicationURL
                }
            }
        }
        return partialMatch
    }

    private func postClick(at quartzPoint: CGPoint, button: CGMouseButton, clickCount: Int64, eventSource: CGEventSource?) {
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        let mouseDownEvent = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: quartzPoint, mouseButton: button)
        let mouseUpEvent = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: quartzPoint, mouseButton: button)
        mouseDownEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        mouseUpEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    private static func eventFlags(for modifiers: ModifierKeys) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
