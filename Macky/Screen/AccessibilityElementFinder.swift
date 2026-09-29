import AppKit
import ApplicationServices
import MackyCore

/// Finds a button, link or menu item by its name in an app's accessibility tree and presses it.
/// This skips the slow "screenshot → ask the model where it is → click" round trip: the model
/// only says "press Play in Spotify" and Macky finds it locally, waiting for it to appear.
/// Runs off the main thread; every Accessibility call has a short timeout.
final class AccessibilityElementFinder: @unchecked Sendable {
    struct PressResult {
        var succeeded: Bool
        var message: String
    }

    private struct Candidate {
        let element: AXUIElement
        let name: String
        let score: Int
        let frameInQuartzCoordinates: CGRect
        var area: CGFloat { frameInQuartzCoordinates.width * frameInQuartzCoordinates.height }
    }

    private static let pressableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXComboBox", "AXTextField", "AXSearchField"
    ]
    private static let maximumVisitedElements = 6000
    private static let pollInterval: TimeInterval = 0.25

    func pressElement(label: String, applicationName: String?, timeout: TimeInterval = 4) async -> PressResult {
        await pressElement(anyOf: [label], applicationName: applicationName, timeout: timeout)
    }

    /// Several names for the same thing, e.g. ["Play", "Redă"] when the app's language is unknown.
    func pressElement(anyOf labels: [String], applicationName: String?, timeout: TimeInterval = 4) async -> PressResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.pressElementWaitingForIt(labels: labels, applicationName: applicationName, timeout: timeout))
            }
        }
    }

    private func pressElementWaitingForIt(labels: [String], applicationName: String?, timeout: TimeInterval) -> PressResult {
        let label = labels.joined(separator: " / ")
        let deadline = Date().addingTimeInterval(timeout)
        var availableNames: [String] = []
        var foundApplication = false
        var enabledChromiumAccessibilityForProcess: pid_t?

        repeat {
            if let application = Self.targetApplication(named: applicationName) {
                foundApplication = true
                let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
                AXUIElementSetMessagingTimeout(applicationElement, 0.5)
                if enabledChromiumAccessibilityForProcess != application.processIdentifier {
                    // Chromium-based apps (Spotify, Slack, VS Code…) only build their accessibility tree when asked to.
                    AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    enabledChromiumAccessibilityForProcess = application.processIdentifier
                }
                let searchResult = Self.search(in: applicationElement, wantedLabels: labels)
                availableNames = searchResult.availableNames
                if let bestMatch = searchResult.bestMatch, Self.press(bestMatch) {
                    return PressResult(succeeded: true, message: "Pressed \"\(bestMatch.name)\".")
                }
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        } while Date() < deadline

        if !foundApplication {
            return PressResult(succeeded: false, message: "The application \(applicationName ?? "in front") is not running.")
        }
        let namesHint = availableNames.isEmpty ? "No named buttons were found." : "Available names: " + availableNames.prefix(40).joined(separator: " | ")
        return PressResult(succeeded: false, message: "No element named \"\(label)\" was found. \(namesHint)")
    }

    private static func targetApplication(named applicationName: String?) -> NSRunningApplication? {
        guard let applicationName, !applicationName.isEmpty else {
            return NSWorkspace.shared.frontmostApplication
        }
        let wantedName = applicationName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let regularApplications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        func normalizedName(of application: NSRunningApplication) -> String {
            (application.localizedName ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return regularApplications.first { normalizedName(of: $0) == wantedName }
            ?? regularApplications.first { normalizedName(of: $0).contains(wantedName) }
    }

    /// Breadth-first walk of the app's windows, scoring every pressable element against the wanted name.
    private static func search(in applicationElement: AXUIElement, wantedLabels: [String]) -> (bestMatch: Candidate?, availableNames: [String]) {
        var queue: [AXUIElement] = windows(of: applicationElement)
        if queue.isEmpty { queue = [applicationElement] }
        // The menu bar holds commands like "File > New" that are useful to press too.
        if let menuBar = copyElementAttribute(kAXMenuBarAttribute, of: applicationElement) {
            queue.append(menuBar)
        }

        var bestMatch: Candidate?
        var availableNames: [String] = []
        var queueIndex = 0
        while queueIndex < queue.count && queueIndex < maximumVisitedElements {
            let element = queue[queueIndex]
            queueIndex += 1
            let attributes = copyAttributes(of: element)
            queue.append(contentsOf: attributes.children)

            guard let role = attributes.role, pressableRoles.contains(role) else { continue }
            let texts = [attributes.title, attributes.description, attributes.value].compactMap { $0 }.filter { !$0.isEmpty }
            guard let displayName = texts.first else { continue }
            if availableNames.count < 60 && !availableNames.contains(displayName) {
                availableNames.append(displayName)
            }
            guard let score = wantedLabels.compactMap({ ElementLabelMatcher.score(elementTexts: texts, wantedLabel: $0) }).max(),
                  let frame = attributes.frame, frame.width > 1, frame.height > 1 else { continue }
            let candidate = Candidate(element: element, name: displayName, score: score, frameInQuartzCoordinates: frame)
            // Best text match wins; among equals, the biggest element (e.g. the big Play button, not a row's).
            if let currentBest = bestMatch {
                if candidate.score > currentBest.score || (candidate.score == currentBest.score && candidate.area > currentBest.area) {
                    bestMatch = candidate
                }
            } else {
                bestMatch = candidate
            }
        }
        return (bestMatch, availableNames)
    }

    private static func press(_ candidate: Candidate) -> Bool {
        if AXUIElementPerformAction(candidate.element, kAXPressAction as CFString) == .success {
            return true
        }
        // Some elements ignore AXPress; a real click in their center still works.
        let center = CGPoint(x: candidate.frameInQuartzCoordinates.midX, y: candidate.frameInQuartzCoordinates.midY)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Attribute reading

    private struct ElementAttributes {
        var role: String?
        var title: String?
        var description: String?
        var value: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    private static let attributeNames = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute
    ] as CFArray

    /// Reads all needed attributes in one round trip to the app (much faster than one call each).
    private static func copyAttributes(of element: AXUIElement) -> ElementAttributes {
        var attributes = ElementAttributes()
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let values = values as? [AnyObject], values.count == 7 else { return attributes }

        attributes.role = values[0] as? String
        attributes.title = values[1] as? String
        attributes.description = values[2] as? String
        attributes.value = values[3] as? String

        var position = CGPoint.zero
        var size = CGSize.zero
        if CFGetTypeID(values[4]) == AXValueGetTypeID(), CFGetTypeID(values[5]) == AXValueGetTypeID(),
           AXValueGetValue(values[4] as! AXValue, .cgPoint, &position),
           AXValueGetValue(values[5] as! AXValue, .cgSize, &size) {
            attributes.frame = CGRect(origin: position, size: size)
        }
        if let children = values[6] as? [AnyObject] {
            attributes.children = children.compactMap { child in
                CFGetTypeID(child) == AXUIElementGetTypeID() ? (child as! AXUIElement) : nil
            }
        }
        return attributes
    }

    private static func windows(of applicationElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AnyObject] else { return [] }
        return windows.compactMap { window in
            CFGetTypeID(window) == AXUIElementGetTypeID() ? (window as! AXUIElement) : nil
        }
    }

    private static func copyElementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
