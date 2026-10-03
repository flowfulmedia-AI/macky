import SwiftUI

@main
struct MackyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Macky lives in the menu bar (LSUIElement); its windows are managed by AppKit controllers.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appEnvironment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ActivityLog.startSession()
        MackyWindowGuard.shared.start()
        let environment = AppEnvironment()
        appEnvironment = environment
        environment.start()
    }

    /// A stray ⌘Q (Macky pressing keys while its own window was in front) must not close Macky mid-task.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let isBusy = appEnvironment?.companionSession.state.isBusy ?? false
        if MackyWindowGuard.shared.allowsTermination(isBusy: isBusy) {
            ActivityLog.note("Închidere cerută: permisă")
            return .terminateNow
        }
        let stack = Thread.callStackSymbols.prefix(25).joined(separator: "\n")
        ActivityLog.note("Închidere cerută în timpul unei sarcini: blocată")
        ErrorLogStore.shared.record("Închidere blocată",
                                    "Ceva a încercat să închidă Macky în timp ce lucra (de obicei o scurtătură ca ⌘Q ajunsă la Macky). Macky a rămas deschis.",
                                    details: stack)
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        appEnvironment?.stop()
        ActivityLog.endSession()
    }
}
