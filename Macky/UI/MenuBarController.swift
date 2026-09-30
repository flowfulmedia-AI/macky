import AppKit
import SwiftUI

/// A panel that can receive keyboard input (for the question text field) without
/// activating Macky or pulling focus from the app the user is working in.
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Menu bar icon plus the dark floating panel that opens under it.
@MainActor
final class MenuBarController: NSObject {
    private static let panelSize = NSSize(width: 820, height: 610)

    private var statusItem: NSStatusItem?
    private var panel: KeyablePanel?
    private var outsideClickMonitor: Any?
    private let makePanelContent: @MainActor () -> AnyView

    init(makePanelContent: @escaping @MainActor () -> AnyView) {
        self.makePanelContent = makePanelContent
    }

    func uninstall() {
        hidePanel()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func install() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Macky")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePanel)
        }
        self.statusItem = statusItem
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanelBelowStatusItem(panel)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView:
            makePanelContent()
                .frame(width: Self.panelSize.width, height: Self.panelSize.height)
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hostingView
        return panel
    }

    private func positionPanelBelowStatusItem(_ panel: NSPanel) {
        guard let buttonWindow = statusItem?.button?.window else {
            panel.center()
            return
        }
        let buttonFrame = buttonWindow.frame
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var originX = buttonFrame.midX - Self.panelSize.width / 2
        originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - Self.panelSize.width - 8)
        let originY = buttonFrame.minY - Self.panelSize.height - 6
        panel.setFrame(NSRect(x: originX, y: originY, width: Self.panelSize.width, height: Self.panelSize.height), display: true)
    }

    /// Clicking anywhere outside Macky closes the panel, like a normal menu.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
            }
        }
    }
}

/// Native translucent dark material behind the panel.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Opens regular windows (Settings, Calibration). Macky has no Dock icon, so it activates
/// itself first; otherwise the windows would open behind the current app.
@MainActor
final class WindowCoordinator {
    private var windowsByIdentifier: [String: NSWindow] = [:]

    func showWindow<Content: View>(identifier: String, title: String, size: NSSize, transparentTitleBar: Bool = false,
                                   content: () -> Content) -> NSWindow {
        if let existingWindow = windowsByIdentifier[identifier] {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return existingWindow
        }
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if transparentTitleBar { styleMask.insert(.fullSizeContentView) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        // All of Macky's windows share the dark look of the panel.
        window.appearance = NSAppearance(named: .darkAqua)
        if transparentTitleBar {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        windowsByIdentifier[identifier] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func window(withIdentifier identifier: String) -> NSWindow? {
        windowsByIdentifier[identifier]
    }
}
