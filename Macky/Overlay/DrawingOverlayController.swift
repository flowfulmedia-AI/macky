import AppKit
import MackyCore

/// Lets the user circle or underline something with the mouse while holding the talk hotkey.
/// During the hold, a transparent window per screen catches mouse drags (so drawing does not
/// click the app underneath). Afterwards the strokes stay visible, but the windows let every
/// click through again, until the answer is finished.
@MainActor
final class DrawingOverlayController {
    /// Strokes in AppKit global coordinates.
    private(set) var strokes: [[CGPoint]] = []
    private var drawingWindows: [NSPanel] = []
    private var isAcceptingInput = false

    /// Strokes big enough to be intentional (a plain click is not a drawing).
    var meaningfulStrokes: [[CGPoint]] {
        strokes.filter { stroke in
            guard stroke.count >= 3 else { return false }
            let bounds = Self.boundingBox(of: stroke)
            return bounds.width >= 12 || bounds.height >= 12
        }
    }

    func beginDrawingSession() {
        strokes.removeAll()
        rebuildWindowsIfNeeded()
        isAcceptingInput = true
        for drawingWindow in drawingWindows {
            drawingWindow.ignoresMouseEvents = false
            drawingWindow.contentView?.needsDisplay = true
            drawingWindow.orderFrontRegardless()
        }
    }

    /// Stops catching the mouse but keeps the drawing on screen.
    func endDrawingSession() {
        isAcceptingInput = false
        for drawingWindow in drawingWindows {
            drawingWindow.ignoresMouseEvents = true
        }
        if strokes.isEmpty {
            hideWindows()
        }
    }

    func clear() {
        isAcceptingInput = false
        strokes.removeAll()
        hideWindows()
    }

    // MARK: Called by the canvas views

    fileprivate func startStroke(at globalPoint: CGPoint) {
        guard isAcceptingInput else { return }
        strokes.append([globalPoint])
        redrawAll()
    }

    fileprivate func continueStroke(to globalPoint: CGPoint) {
        guard isAcceptingInput, !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(globalPoint)
        redrawAll()
    }

    // MARK: Private

    private func redrawAll() {
        drawingWindows.forEach { $0.contentView?.needsDisplay = true }
    }

    private func hideWindows() {
        drawingWindows.forEach { $0.orderOut(nil) }
    }

    private func rebuildWindowsIfNeeded() {
        let currentScreenFrames = NSScreen.screens.map(\.frame)
        guard drawingWindows.map(\.frame) != currentScreenFrames else { return }
        drawingWindows.forEach { $0.orderOut(nil) }
        drawingWindows = NSScreen.screens.map(makeDrawingWindow)
    }

    private func makeDrawingWindow(for screen: NSScreen) -> NSPanel {
        let drawingWindow = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        drawingWindow.isOpaque = false
        // Almost transparent instead of fully clear: fully clear windows let clicks fall through.
        drawingWindow.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        drawingWindow.hasShadow = false
        drawingWindow.level = .statusBar
        drawingWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        drawingWindow.hidesOnDeactivate = false
        drawingWindow.isReleasedWhenClosed = false
        drawingWindow.sharingType = .none
        let canvasView = DrawingCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvasView.controller = self
        drawingWindow.contentView = canvasView
        drawingWindow.setFrame(screen.frame, display: false)
        return drawingWindow
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let firstPoint = points.first else { return .zero }
        var minimumX = firstPoint.x, maximumX = firstPoint.x
        var minimumY = firstPoint.y, maximumY = firstPoint.y
        for point in points {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
    }
}

/// Catches the mouse and paints every stroke that crosses this screen.
private final class DrawingCanvasView: NSView {
    weak var controller: DrawingOverlayController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let globalPoint = globalPoint(of: event) else { return }
        MainActor.assumeIsolated { controller?.startStroke(at: globalPoint) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let globalPoint = globalPoint(of: event) else { return }
        MainActor.assumeIsolated { controller?.continueStroke(to: globalPoint) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let strokes = MainActor.assumeIsolated({ controller?.strokes }) else { return }
        let windowOrigin = window.frame.origin
        let accentColor = NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.70, alpha: 1)

        let glow = NSShadow()
        glow.shadowColor = accentColor.withAlphaComponent(0.8)
        glow.shadowBlurRadius = 8
        glow.set()

        for stroke in strokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: stroke[0].x - windowOrigin.x, y: stroke[0].y - windowOrigin.y))
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x - windowOrigin.x, y: point.y - windowOrigin.y))
            }
            accentColor.setStroke()
            path.stroke()
        }
    }

    private func globalPoint(of event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
    }
}
