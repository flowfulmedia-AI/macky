import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Everything needed to map a point in a screenshot back to the real screen.
public struct CapturedScreenGeometry: Equatable, Sendable {
    /// 1-based number the model sees ("screenshot 1"). Screenshot 1 is the screen with the mouse.
    public var screenNumber: Int
    public var displayIdentifier: UInt32
    /// The screen's frame in AppKit global coordinates (points, origin bottom-left of the primary screen, y up).
    public var frameInAppKitGlobalCoordinates: CGRect
    /// Size of the image actually sent to the model, after downscaling.
    public var imagePixelSize: CGSize

    public init(screenNumber: Int, displayIdentifier: UInt32, frameInAppKitGlobalCoordinates: CGRect, imagePixelSize: CGSize) {
        self.screenNumber = screenNumber
        self.displayIdentifier = displayIdentifier
        self.frameInAppKitGlobalCoordinates = frameInAppKitGlobalCoordinates
        self.imagePixelSize = imagePixelSize
    }
}

/// macOS uses three coordinate spaces that are easy to mix up:
/// - Image pixels: what the model sees. Origin top-left, y down, downscaled.
/// - AppKit global points (NSScreen, NSWindow, NSEvent.mouseLocation): origin bottom-left of the
///   primary screen, y up. Secondary screens can have negative coordinates.
/// - Quartz global points (CGEvent, Accessibility, CGWindow): origin top-left of the primary screen, y down.
/// Overlay SwiftUI views use a fourth, local space: origin top-left of their own screen.
public enum ScreenGeometry {
    /// Size to capture a screen at so the long edge fits `maximumLongEdge` pixels, never exceeding native resolution.
    public static func capturePixelSize(screenPointSize: CGSize, backingScaleFactor: Double, maximumLongEdge: Double) -> CGSize {
        let nativeWidth = Double(screenPointSize.width) * backingScaleFactor
        let nativeHeight = Double(screenPointSize.height) * backingScaleFactor
        let longEdge = max(nativeWidth, nativeHeight)
        guard longEdge > 0 else { return .zero }
        let scale = min(1, maximumLongEdge / longEdge)
        return CGSize(width: (nativeWidth * scale).rounded(), height: (nativeHeight * scale).rounded())
    }

    public static func appKitGlobalPoint(fromImagePixel imagePixel: CGPoint, on screen: CapturedScreenGeometry) -> CGPoint {
        let frame = screen.frameInAppKitGlobalCoordinates
        let fractionX = Double(imagePixel.x) / Double(screen.imagePixelSize.width)
        let fractionFromTop = Double(imagePixel.y) / Double(screen.imagePixelSize.height)
        return CGPoint(
            x: Double(frame.minX) + fractionX * Double(frame.width),
            y: Double(frame.maxY) - fractionFromTop * Double(frame.height)
        )
    }

    public static func imagePixel(fromAppKitGlobalPoint point: CGPoint, on screen: CapturedScreenGeometry) -> CGPoint {
        let frame = screen.frameInAppKitGlobalCoordinates
        let fractionX = (Double(point.x) - Double(frame.minX)) / Double(frame.width)
        let fractionFromTop = (Double(frame.maxY) - Double(point.y)) / Double(frame.height)
        return CGPoint(
            x: fractionX * Double(screen.imagePixelSize.width),
            y: fractionFromTop * Double(screen.imagePixelSize.height)
        )
    }

    /// `primaryScreenHeight` is the height of the screen that holds the menu bar (NSScreen.screens[0]).
    public static func quartzGlobalPoint(fromAppKitGlobalPoint point: CGPoint, primaryScreenHeight: Double) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - Double(point.y))
    }

    public static func appKitGlobalPoint(fromQuartzGlobalPoint point: CGPoint, primaryScreenHeight: Double) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - Double(point.y))
    }

    public static func appKitGlobalRect(fromQuartzGlobalRect rect: CGRect, primaryScreenHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - Double(rect.maxY), width: rect.width, height: rect.height)
    }

    /// Converts to the top-left-origin local space of an overlay window covering `overlayFrameInAppKitGlobalCoordinates`.
    public static func overlayLocalPoint(fromAppKitGlobalPoint point: CGPoint, overlayFrameInAppKitGlobalCoordinates overlayFrame: CGRect) -> CGPoint {
        CGPoint(x: Double(point.x) - Double(overlayFrame.minX), y: Double(overlayFrame.maxY) - Double(point.y))
    }

    public static func overlayLocalRect(fromAppKitGlobalRect rect: CGRect, overlayFrameInAppKitGlobalCoordinates overlayFrame: CGRect) -> CGRect {
        CGRect(
            x: Double(rect.minX) - Double(overlayFrame.minX),
            y: Double(overlayFrame.maxY) - Double(rect.maxY),
            width: rect.width,
            height: rect.height
        )
    }

    public static func distance(from firstPoint: CGPoint, to secondPoint: CGPoint) -> Double {
        let deltaX = Double(firstPoint.x) - Double(secondPoint.x)
        let deltaY = Double(firstPoint.y) - Double(secondPoint.y)
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }

    /// Point on a quadratic Bézier arc used for the cursor flight. `progress` goes from 0 to 1.
    /// The control point is lifted perpendicular to the path so the cursor travels on a gentle curve.
    public static func pointOnFlightArc(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        let clampedProgress = min(max(progress, 0), 1)
        let startX = Double(start.x), startY = Double(start.y)
        let endX = Double(end.x), endY = Double(end.y)
        let pathLength = distance(from: start, to: end)
        let lift = min(pathLength * 0.25, 160)
        let midpointX = (startX + endX) / 2
        let midpointY = (startY + endY) / 2
        var perpendicularX = 0.0, perpendicularY = 0.0
        if pathLength > 0 {
            perpendicularX = -(endY - startY) / pathLength
            perpendicularY = (endX - startX) / pathLength
        }
        let controlX = midpointX + perpendicularX * lift
        let controlY = midpointY + perpendicularY * lift
        let inverse = 1 - clampedProgress
        return CGPoint(
            x: inverse * inverse * startX + 2 * inverse * clampedProgress * controlX + clampedProgress * clampedProgress * endX,
            y: inverse * inverse * startY + 2 * inverse * clampedProgress * controlY + clampedProgress * clampedProgress * endY
        )
    }

    /// Ease-in-out curve so the flight starts and ends softly.
    public static func easeInOut(_ progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress < 0.5
            ? 2 * clampedProgress * clampedProgress
            : 1 - pow(-2 * clampedProgress + 2, 2) / 2
    }
}
