import AppKit
import ApplicationServices
import MackyCore

struct AccessibilityElementInfo {
    let role: String
    let title: String?
    let frameInQuartzGlobalCoordinates: CGRect
    let processIdentifier: pid_t
}

/// The app and window the user was working in when they asked.
struct FrontmostApplicationSnapshot {
    var context: FrontmostApplicationContext
    let processIdentifier: pid_t?
    let focusedWindowFrameInQuartzCoordinates: CGRect?
}

/// Reads the Accessibility (AX) tree: which app/window is in front, and which real UI
/// element sits under a point. Needs the Accessibility permission; without it every
/// method degrades gracefully and pointing falls back to the model's coordinates.
@MainActor
final class AccessibilityInspector {
    private let systemWideElement = AXUIElementCreateSystemWide()
    /// Short timeouts: a frozen app must never freeze Macky.
    private static let messagingTimeoutInSeconds: Float = 0.25

    init() {
        AXUIElementSetMessagingTimeout(systemWideElement, Self.messagingTimeoutInSeconds)
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func frontmostApplicationSnapshot() -> FrontmostApplicationSnapshot {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return FrontmostApplicationSnapshot(context: FrontmostApplicationContext(applicationName: nil, windowTitle: nil), processIdentifier: nil, focusedWindowFrameInQuartzCoordinates: nil)
        }
        let processIdentifier = frontmostApplication.processIdentifier
        var windowTitle: String?
        var windowFrame: CGRect?
        if isTrusted, let focusedWindow = focusedWindow(ofProcess: processIdentifier) {
            windowTitle = stringAttribute(kAXTitleAttribute, of: focusedWindow)
            windowFrame = frame(of: focusedWindow)
        }
        let selectedText = isTrusted ? self.selectedText(inProcess: processIdentifier) : nil
        return FrontmostApplicationSnapshot(
            context: FrontmostApplicationContext(applicationName: frontmostApplication.localizedName, windowTitle: windowTitle, selectedText: selectedText),
            processIdentifier: processIdentifier,
            focusedWindowFrameInQuartzCoordinates: windowFrame
        )
    }

    func focusedWindowFrame(ofProcess processIdentifier: pid_t) -> CGRect? {
        guard isTrusted, let focusedWindow = focusedWindow(ofProcess: processIdentifier) else { return nil }
        return frame(of: focusedWindow)
    }

    /// Finds the control under a point. A label or icon inside a button resolves to the button itself.
    func interactiveElement(atQuartzGlobalPoint point: CGPoint) -> AccessibilityElementInfo? {
        guard isTrusted else { return nil }
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hitElement) == .success,
              var currentElement = hitElement else {
            return nil
        }

        var fallbackCandidate: AccessibilityElementInfo?
        for _ in 0..<4 {
            if let elementInfo = describe(currentElement) {
                let isInteractive = AccessibilitySnapPolicy.interactiveRoles.contains(elementInfo.role)
                let prefersParent = AccessibilitySnapPolicy.rolesThatPreferParent.contains(elementInfo.role)
                if isInteractive && !prefersParent { return elementInfo }
                if isInteractive && fallbackCandidate == nil { fallbackCandidate = elementInfo }
            }
            guard let parentValue = copyAttribute(kAXParentAttribute, of: currentElement),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            currentElement = parentValue as! AXUIElement
        }
        return fallbackCandidate
    }

    /// The text selected in the focused field of an app, when the app exposes it through Accessibility.
    private func selectedText(inProcess processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, Self.messagingTimeoutInSeconds)
        guard let focusedValue = copyAttribute(kAXFocusedUIElementAttribute, of: applicationElement),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = focusedValue as! AXUIElement
        guard let text = stringAttribute(kAXSelectedTextAttribute, of: focusedElement),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private func focusedWindow(ofProcess processIdentifier: pid_t) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, Self.messagingTimeoutInSeconds)
        guard let windowValue = copyAttribute(kAXFocusedWindowAttribute, of: applicationElement),
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement)
    }

    private func describe(_ element: AXUIElement) -> AccessibilityElementInfo? {
        guard let role = stringAttribute(kAXRoleAttribute, of: element),
              let elementFrame = frame(of: element) else { return nil }
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        let title = stringAttribute(kAXTitleAttribute, of: element) ?? stringAttribute(kAXDescriptionAttribute, of: element)
        return AccessibilityElementInfo(role: role, title: title, frameInQuartzGlobalCoordinates: elementFrame, processIdentifier: processIdentifier)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(kAXPositionAttribute, of: element),
              let sizeValue = copyAttribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        copyAttribute(attribute, of: element) as? String
    }

    private func copyAttribute(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
