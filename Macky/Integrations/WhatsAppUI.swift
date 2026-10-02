import AppKit
import ApplicationServices

/// Reads and drives the WhatsApp window through Accessibility, to open a group chat
/// (WhatsApp has no link that opens a group). Every step is checked against what the window shows.
enum WhatsAppUI {
    struct Node {
        let element: AXUIElement
        let role: String
        let texts: [String]
        let frame: CGRect
    }

    struct Snapshot {
        let window: CGRect
        let nodes: [Node]
    }

    private static let textInputRoles: Set<String> = ["AXTextField", "AXSearchField", "AXTextArea", "AXComboBox"]

    // MARK: Reading

    static func snapshot(processIdentifier: pid_t) -> Snapshot? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.0)
        guard let window = element(kAXFocusedWindowAttribute, of: application)
                ?? element(kAXMainWindowAttribute, of: application)
                ?? windows(of: application).first,
              let windowFrame = frame(of: window) else { return nil }

        var nodes: [Node] = []
        var queue = [window]
        var index = 0
        while index < queue.count && index < 6000 {
            let current = queue[index]
            index += 1
            let attributes = readAttributes(of: current)
            queue.append(contentsOf: attributes.children)
            guard let elementFrame = attributes.frame, elementFrame.width > 1, elementFrame.height > 1 else { continue }
            var texts = attributes.texts
            if textInputRoles.contains(attributes.role), let placeholder = string(kAXPlaceholderValueAttribute, of: current) {
                texts.append(placeholder)
            }
            nodes.append(Node(element: current, role: attributes.role, texts: texts, frame: elementFrame))
        }
        return Snapshot(window: windowFrame, nodes: nodes)
    }

    /// The chat named `name` in the left column (the chat list or search results), topmost first.
    static func chatRow(named name: String, in snapshot: Snapshot, below minimumY: CGFloat? = nil) -> Node? {
        let wanted = fold(name)
        let leftEdge = snapshot.window.minX + snapshot.window.width * 0.5
        return snapshot.nodes
            .filter { node in
                !textInputRoles.contains(node.role)
                    && node.frame.midX < leftEdge
                    && node.frame.height < 160
                    && (minimumY.map { node.frame.minY > $0 } ?? true)
                    && node.texts.contains { startsWithName(fold($0), wanted) }
            }
            .sorted { $0.frame.minY < $1.frame.minY }
            .first
    }

    /// The search field at the top of the chat list.
    static func searchField(in snapshot: Snapshot) -> Node? {
        let leftEdge = snapshot.window.minX + snapshot.window.width * 0.5
        let fields = snapshot.nodes.filter { textInputRoles.contains($0.role) && $0.frame.midX < leftEdge }
        let searchWords = ["search", "caut", "find"]
        return fields.first { node in node.texts.contains { text in searchWords.contains { fold(text).contains($0) } } }
            ?? fields.sorted { $0.frame.minY < $1.frame.minY }.first
    }

    /// True when the open conversation's header (top of the right side) shows `name`.
    static func conversationIsOpen(named name: String, in snapshot: Snapshot) -> Bool {
        let wanted = fold(name)
        let window = snapshot.window
        return snapshot.nodes.contains { node in
            node.frame.midX > window.minX + window.width * 0.3
                && node.frame.minY < window.minY + window.height * 0.25
                && node.texts.contains { startsWithName(fold($0), wanted) }
        }
    }

    /// The message box at the bottom of the open conversation.
    static func messageBox(in snapshot: Snapshot) -> Node? {
        let window = snapshot.window
        return snapshot.nodes
            .filter { textInputRoles.contains($0.role) && $0.frame.midX > window.minX + window.width * 0.3 && $0.frame.midY > window.minY + window.height * 0.6 }
            .sorted { $0.frame.maxY > $1.frame.maxY }
            .first
    }

    /// What the window shows, for diagnosing a failed attempt.
    static func describe(_ snapshot: Snapshot) -> String {
        var lines = ["Window: \(snapshot.window)"]
        for node in snapshot.nodes where !node.texts.isEmpty || textInputRoles.contains(node.role) {
            lines.append("\(node.role) \(Int(node.frame.minX)),\(Int(node.frame.minY)) \(Int(node.frame.width))x\(Int(node.frame.height)) · \(node.texts.joined(separator: " | ").prefix(120))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Acting

    /// A real click in the middle of the element (Accessibility and click events share screen coordinates).
    static func click(_ node: Node) {
        if AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success, !textInputRoles.contains(node.role) {
            return
        }
        let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: Helpers

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Familia Cozma" matches "Familia Cozma", "Familia Cozma, 10:42, Ana: ..." but not "Familia Cozmanescu".
    private static func startsWithName(_ text: String, _ name: String) -> Bool {
        guard text.hasPrefix(name) else { return false }
        guard let next = text.dropFirst(name.count).first else { return true }
        return !next.isLetter && !next.isNumber
    }

    private struct Attributes {
        var role = ""
        var texts: [String] = []
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    private static let attributeNames = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute
    ] as CFArray

    private static func readAttributes(of element: AXUIElement) -> Attributes {
        var attributes = Attributes()
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let values = values as? [AnyObject], values.count == 7 else { return attributes }
        attributes.role = values[0] as? String ?? ""
        attributes.texts = [values[1], values[2], values[3]].compactMap { $0 as? String }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var position = CGPoint.zero
        var size = CGSize.zero
        if CFGetTypeID(values[4]) == AXValueGetTypeID(), CFGetTypeID(values[5]) == AXValueGetTypeID(),
           AXValueGetValue(values[4] as! AXValue, .cgPoint, &position),
           AXValueGetValue(values[5] as! AXValue, .cgSize, &size) {
            attributes.frame = CGRect(origin: position, size: size)
        }
        if let children = values[6] as? [AnyObject] {
            attributes.children = children.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return attributes
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AnyObject] else { return [] }
        return windows.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
