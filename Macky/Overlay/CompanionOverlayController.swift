import AppKit
import Combine
import MackyCore
import SwiftUI

enum CompanionOverlayActivity: Equatable {
    case listening
    case dictating
    case thinking
    case speaking
    case pointing
    case error
}

/// State shared by the overlay windows on every screen. Positions are AppKit global coordinates.
@MainActor
final class CompanionOverlayModel: ObservableObject {
    @Published var isVisible = false
    @Published var activity: CompanionOverlayActivity = .thinking
    /// Where the tip of Macky's cursor is.
    @Published var cursorTipPosition: CGPoint = .zero
    @Published var audioLevel: Float = 0
    @Published var bubbleText: String?
    @Published var pointingLabel: String?
    @Published var highlightRect: CGRect?
}

/// Owns one transparent, click-through window per screen and animates Macky's cursor.
/// The windows never take focus, join every Space (including full-screen apps) and are
/// excluded from screenshots so Macky never sees itself.
@MainActor
final class CompanionOverlayController {
    let model = CompanionOverlayModel()

    /// Macky sits just below-right of the real mouse pointer while following it.
    private static let offsetFromMousePointer = CGSize(width: 18, height: -22)

    private var overlayWindows: [NSPanel] = []
    private var mouseFollowTimer: Timer?
    private var flightTimer: Timer?
    private var flightCompletion: CheckedContinuation<Void, Never>?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var screenChangeObserver: NSObjectProtocol?

    private(set) var isShowingPointing = false

    func start() {
        rebuildOverlayWindows()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Screens were added, removed or rearranged: old targets are no longer valid.
                self?.clearPointing()
                self?.rebuildOverlayWindows()
            }
        }
    }

    // MARK: Interaction lifecycle

    func beginInteraction(activity: CompanionOverlayActivity) {
        cancelPendingHide()
        stopFlight()
        clearPointing()
        model.bubbleText = nil
        model.audioLevel = 0
        model.activity = activity
        model.cursorTipPosition = Self.followPosition()
        model.isVisible = true
        startFollowingMouse()
    }

    /// Used for errors: shows the overlay near the mouse if it is not already visible.
    func beginInteractionIfHidden(activity: CompanionOverlayActivity) {
        guard !model.isVisible else { return }
        beginInteraction(activity: activity)
    }

    func setActivity(_ activity: CompanionOverlayActivity) {
        model.activity = activity
    }

    func setAudioLevel(_ audioLevel: Float) {
        model.audioLevel = audioLevel
    }

    func setBubbleText(_ text: String?) {
        guard let text, !text.isEmpty else {
            model.bubbleText = nil
            return
        }
        // Only the end of long answers fits in the bubble; the full text is in the menu bar panel.
        let maximumBubbleCharacters = 280
        model.bubbleText = text.count > maximumBubbleCharacters ? "…" + text.suffix(maximumBubbleCharacters) : text
    }

    /// Fades the overlay out after `delay`, unless something new starts first.
    func endInteraction(afterDelay delay: TimeInterval) {
        cancelPendingHide()
        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hideImmediately()
        }
        pendingHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hideWorkItem)
    }

    func hideImmediately() {
        cancelPendingHide()
        stopFlight()
        stopFollowingMouse()
        clearPointing()
        model.isVisible = false
        model.bubbleText = nil
    }

    // MARK: Pointing

    /// Flies the cursor to `targetPoint` along an arc, then shows the highlight and label.
    func flyCursor(to targetPoint: CGPoint, highlightRect: CGRect?, label: String) async {
        cancelPendingHide()
        stopFollowingMouse()
        stopFlight()
        isShowingPointing = true
        model.isVisible = true
        model.activity = .pointing
        model.highlightRect = nil
        model.pointingLabel = nil

        let startPoint = model.cursorTipPosition
        let travelDistance = ScreenGeometry.distance(from: startPoint, to: targetPoint)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if !reduceMotion && travelDistance > 2 {
            let flightDuration = min(max(travelDistance / 1400, 0.35), 0.9)
            let flightStartDate = Date()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                flightCompletion = continuation
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let elapsedFraction = Date().timeIntervalSince(flightStartDate) / flightDuration
                        let easedProgress = ScreenGeometry.easeInOut(elapsedFraction)
                        self.model.cursorTipPosition = ScreenGeometry.pointOnFlightArc(from: startPoint, to: targetPoint, progress: easedProgress)
                        if elapsedFraction >= 1 {
                            self.finishFlight()
                        }
                    }
                }
                flightTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        model.cursorTipPosition = targetPoint
        model.highlightRect = highlightRect
        model.pointingLabel = label.isEmpty ? nil : label
    }

    func clearPointing() {
        isShowingPointing = false
        model.highlightRect = nil
        model.pointingLabel = nil
    }

    // MARK: Private

    private func rebuildOverlayWindows() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = NSScreen.screens.map(makeOverlayWindow)
    }

    private func makeOverlayWindow(for screen: NSScreen) -> NSPanel {
        let overlayWindow = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.level = .statusBar
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlayWindow.hidesOnDeactivate = false
        overlayWindow.isReleasedWhenClosed = false
        // Keeps the overlay out of every screenshot, including Macky's own.
        overlayWindow.sharingType = .none
        overlayWindow.contentView = NSHostingView(rootView: CompanionOverlayView(model: model, screenFrame: screen.frame))
        overlayWindow.setFrame(screen.frame, display: false)
        overlayWindow.orderFrontRegardless()
        return overlayWindow
    }

    private func startFollowingMouse() {
        guard mouseFollowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.cursorTipPosition = CompanionOverlayController.followPosition()
            }
        }
        mouseFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFollowingMouse() {
        mouseFollowTimer?.invalidate()
        mouseFollowTimer = nil
    }

    private func stopFlight() {
        finishFlight()
    }

    /// Ends the current flight and resumes whoever is awaiting it, so an interrupted flight never hangs.
    private func finishFlight() {
        flightTimer?.invalidate()
        flightTimer = nil
        let completion = flightCompletion
        flightCompletion = nil
        completion?.resume()
    }

    private func cancelPendingHide() {
        pendingHideWorkItem?.cancel()
        pendingHideWorkItem = nil
    }

    private static func followPosition() -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        return CGPoint(x: mouseLocation.x + offsetFromMousePointer.width, y: mouseLocation.y + offsetFromMousePointer.height)
    }
}
