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
        let environment = AppEnvironment()
        appEnvironment = environment
        environment.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appEnvironment?.stop()
    }
}
