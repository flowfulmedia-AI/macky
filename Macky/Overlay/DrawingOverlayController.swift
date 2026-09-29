import AppKit
import MackyCore

/// Lets the user mark something on screen while holding the talk hotkey: the mouse pointer
/// leaves a trail as it moves, no clicking needed. The trail disappears as soon as the keys
/// are released; the strokes are kept in memory so they can be painted into the screenshot.
/// The windows never catch the mouse, so clicks always reach the apps underneath.
@MainActor
final class DrawingOverlayController {
    /// Strokes in AppKit global coordinates.
    private(set) var strokes: [[CGPoint]] = []
    private var drawingWindows: [NSPanel] = []
    private var mouseTrackingTimer: Timer?
    /// Points closer than this to the previous one are skipped, so a still mouse draws nothing.
    private static let minimumPointSpacing: CGFloat = 1.5

    /// Strokes big enough to be intentional (a slightly nudged mouse is not a drawing).
    var meaningfulStrokes: [[CGPoint]] {
        strokes.filter { stroke in
            guard stroke.count >= 3 else { return false }
            let bounds = Self.boundingBox(of: stroke)
            return bounds.width >= 20 || bounds.height >= 20
        }
    }

    func beginDrawingSession() {
        stopTrackingMouse()
        // The trail starts where the mouse is when the keys go down.
        strokes = [[NSEvent.mouseLocation]]
        rebuildWindowsIfNeeded()
        for drawingWindow in drawingWindows {
            drawingWindow.contentView?.needsDisplay = true
            drawingWindow.orderFrontRegardless()
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordMousePosition()
            }
        }
        mouseTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops drawing and removes the trail from the screen. `strokes` keeps the drawing until the next session.
    func endDrawingSession() {
        stopTrackingMouse()
        hideWindows()
    }

    func clear() {
        stopTrackingMouse()
        strokes.removeAll()
        hideWindows()
    }

    fileprivate var strokesToDraw: [[CGPoint]] { strokes }

    // MARK: Private

    private func recordMousePosition() {
        let mouseLocation = NSEvent.mouseLocation
        guard !strokes.isEmpty, let lastPoint = strokes[strokes.count - 1].last else { return }
        guard hypot(mouseLocation.x - lastPoint.x, mouseLocation.y - lastPoint.y) >= Self.minimumPointSpacing else { return }
        strokes[strokes.count - 1].append(mouseLocation)
        drawingWindows.forEach { $0.contentView?.needsDisplay = true }
    }

    private func stopTrackingMouse() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
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
        drawingWindow.backgroundColor = .clear
        drawingWindow.hasShadow = false
        drawingWindow.ignoresMouseEvents = true
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

/// Paints every stroke that crosses this screen.
private final class DrawingCanvasView: NSView {
    weak var controller: DrawingOverlayController?

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let strokes = MainActor.assumeIsolated({ controller?.strokesToDraw }) else { return }
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
}
