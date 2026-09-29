import AppKit

/// Types dictated text into whatever field has focus, by pasting it.
/// Pasting handles every language and emoji correctly, unlike simulating individual keystrokes.
/// The previous clipboard content is restored afterwards. Needs the Accessibility permission.
@MainActor
final class DictationTextInserter {
    private static let virtualKeyCodeForV: CGKeyCode = 9

    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedPasteboardItems = Self.copyItems(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWritingDictation = pasteboard.changeCount

        postCommandV()

        // Give the target app time to read the clipboard before putting the old content back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // If something else wrote to the clipboard meanwhile, leave it alone.
            guard pasteboard.changeCount == changeCountAfterWritingDictation else { return }
            pasteboard.clearContents()
            if !savedPasteboardItems.isEmpty {
                pasteboard.writeObjects(savedPasteboardItems)
            }
        }
    }

    private func postCommandV() {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: Self.virtualKeyCodeForV, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: Self.virtualKeyCodeForV, keyDown: false)
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cgAnnotatedSessionEventTap)
        keyUpEvent?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func copyItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for type in originalItem.types {
                if let data = originalItem.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }
            return copiedItem
        }
    }
}
