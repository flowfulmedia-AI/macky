import AppKit
import Darwin
import Foundation

/// Keeps Macky from closing or clicking itself by accident while it works on other apps.
///
/// Macky's own windows are left out of the screenshots the model sees, so a click aimed at what lies beneath one
/// of them, or a shortcut like ⌘Q or ⌘W pressed while Macky's chat window is in front, would land on Macky itself.
@MainActor
final class MackyWindowGuard {
    static let shared = MackyWindowGuard()

    /// Set by Macky's own "Ieșire" and "Repornește" buttons.
    var userRequestedQuit = false
    private(set) var lastSyntheticInputDate: Date?
    private var lastExternalApplication: NSRunningApplication?
    private var windowsMovedAside: [NSWindow] = []
    private var activationObserver: NSObjectProtocol?

    private init() {}

    func start() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current { lastExternalApplication = frontmost }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let application, application != .current { MackyWindowGuard.shared.lastExternalApplication = application }
            }
        }
    }

    /// Before Macky clicks, types or presses keys: the target app comes to the front instead of Macky,
    /// and Macky's windows under the click are moved aside until the task ends.
    func prepareForInput(clickPoint: CGPoint?) async {
        lastSyntheticInputDate = Date()
        if let clickPoint {
            for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents && window.frame.contains(clickPoint) {
                window.orderOut(nil)
                windowsMovedAside.append(window)
            }
        }
        if NSApp.isActive {
            let target = lastExternalApplication.flatMap { $0.isTerminated ? nil : $0 }
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            ActivityLog.note("Macky era în față; activez \(target?.localizedName ?? "altă aplicație") înainte de acțiune")
            target?.activate()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        lastSyntheticInputDate = Date()
    }

    /// Brings back the windows moved aside for clicks.
    func restoreWindows() {
        let windows = windowsMovedAside
        windowsMovedAside = []
        for window in windows where !window.isVisible {
            window.orderFront(nil)
        }
    }

    /// Quitting is allowed when the user asked for it, when macOS shuts down or logs out, and otherwise only when
    /// Macky is idle and has not just sent keystrokes or clicks (which could have been a stray ⌘Q).
    func allowsTermination(isBusy: Bool) -> Bool {
        if userRequestedQuit { return true }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return true
        }
        let recentlyActed = lastSyntheticInputDate.map { Date().timeIntervalSince($0) < 20 } ?? false
        return !isBusy && !recentlyActed
    }
}

/// A short trail of what Macky did (requests, actions, answers) in ~/Library/Logs/Macky/activity.log.
/// When Macky ends without quitting normally, the next launch shows the last steps in Erori.
enum ActivityLog {
    private static let folderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Macky", isDirectory: true)
    private static let fileURL = folderURL.appendingPathComponent("activity.log")
    private static let sessionOpenKey = "activityLogSessionOpen"
    private static let lock = NSLock()
    static var crashFileDescriptor: Int32 = -1

    /// At launch: reports an unexpected end of the previous run, trims the file and starts a new section.
    @MainActor
    static func startSession() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let previousLines = (try? String(contentsOf: fileURL, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        if UserDefaults.standard.bool(forKey: sessionOpenKey) {
            let lastSession = previousLines.lastIndex { $0.contains("— Macky pornit") }.map { Array(previousLines[$0...]) } ?? previousLines
            let crashLine = lastSession.last { $0.contains("SEMNAL") }
            ErrorLogStore.shared.record(
                "Închidere neașteptată",
                "Macky s-a oprit fără să fie închis normal" + (crashLine.map { " (\($0.components(separatedBy: "] ").last ?? $0))" } ?? "")
                    + ". Ultimii pași sunt în detalii.",
                details: lastSession.suffix(30).joined(separator: "\n")
            )
        }
        let kept = previousLines.suffix(400).joined(separator: "\n")
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(true, forKey: sessionOpenKey)
        note("— Macky pornit")
        installCrashHandlers()
    }

    /// A normal quit (or `pkill` from make run): nothing to report next time.
    static func endSession() {
        note("— Macky închis normal")
        UserDefaults.standard.set(false, forKey: sessionOpenKey)
        UserDefaults.standard.synchronize()
    }

    static func note(_ text: String) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let line = "[\(formatter.string(from: Date()))] " + text.replacingOccurrences(of: "\n", with: " ").prefix(400) + "\n"
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? line.write(to: fileURL, atomically: false, encoding: .utf8)
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    private static var signalSources: [DispatchSourceSignal] = []

    private static func installCrashHandlers() {
        crashFileDescriptor = open(fileURL.path, O_WRONLY | O_APPEND)
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(signalNumber) { number in
                // Only async-signal-safe calls here: a fixed message, then the default handler (crash report).
                let message = "[crash] SEMNAL \(number) — Macky s-a blocat\n"
                message.withCString { pointer in _ = write(ActivityLog.crashFileDescriptor, pointer, strlen(pointer)) }
                signal(number, SIG_DFL)
                raise(number)
            }
        }
        NSSetUncaughtExceptionHandler { exception in
            ActivityLog.note("SEMNAL excepție: \(exception.name.rawValue): \(exception.reason ?? "") \(exception.callStackSymbols.prefix(12).joined(separator: " | "))")
        }
        // `make run` stops the old copy with SIGTERM: a normal end.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler {
            endSession()
            exit(0)
        }
        termination.resume()
        signalSources.append(termination)
    }
}
