import AppKit
import MackyCore

/// Watches the keyboard system-wide for the hold-to-talk and hold-to-dictate combinations.
/// Uses a listen-only CGEvent tap: it can see modifier keys even while other apps are in
/// front, but it can never block or change keystrokes. Requires the Input Monitoring permission.
final class GlobalHotkeyMonitor {
    /// Delivered on the main thread.
    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeyStateMachine: HotkeyStateMachine

    var isRunning: Bool { eventTap != nil }

    init(talkCombination: ModifierKeys, dictationCombination: ModifierKeys?) {
        hotkeyStateMachine = HotkeyStateMachine(talkCombination: talkCombination, dictationCombination: dictationCombination)
    }

    func updateCombinations(talkCombination: ModifierKeys, dictationCombination: ModifierKeys?) {
        hotkeyStateMachine = HotkeyStateMachine(talkCombination: talkCombination, dictationCombination: dictationCombination)
    }

    /// Returns false when macOS refuses the tap (Input Monitoring not granted yet).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: globalHotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        eventTap = createdEventTap
        runLoopSource = createdRunLoopSource
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called on the main thread because the tap's run loop source lives on the main run loop.
    fileprivate func handle(eventType: CGEventType, event: CGEvent) {
        let hotkeyEvents: [HotkeyEvent]
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; turn it straight back on.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        case .flagsChanged:
            hotkeyEvents = hotkeyStateMachine.handleModifiersChanged(Self.modifierKeys(from: event.flags))
        case .keyDown:
            hotkeyEvents = hotkeyStateMachine.handleRegularKeyPressed()
        default:
            return
        }
        for hotkeyEvent in hotkeyEvents {
            onHotkeyEvent?(hotkeyEvent)
        }
    }

    private static func modifierKeys(from flags: CGEventFlags) -> ModifierKeys {
        var modifierKeys: ModifierKeys = []
        if flags.contains(.maskControl) { modifierKeys.insert(.control) }
        if flags.contains(.maskAlternate) { modifierKeys.insert(.option) }
        if flags.contains(.maskShift) { modifierKeys.insert(.shift) }
        if flags.contains(.maskCommand) { modifierKeys.insert(.command) }
        return modifierKeys
    }
}

private func globalHotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    eventType: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(eventType: eventType, event: event)
    }
    return Unmanaged.passUnretained(event)
}
