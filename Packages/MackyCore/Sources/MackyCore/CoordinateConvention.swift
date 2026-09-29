import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a model expresses positions on a screenshot. Vision models are trained differently:
/// Claude and GPT answer best in pixels of the image they received, while Gemini and
/// Qwen3-VL are trained to answer on a 0–1000 grid regardless of the image size.
/// The same convention drives both the prompt we send and how we read the answer.
public enum CoordinateConvention: String, CaseIterable, Codable, Sendable {
    case imagePixels
    case normalizedTo1000

    public var displayName: String {
        switch self {
        case .imagePixels: return "Pixeli ai imaginii"
        case .normalizedTo1000: return "Normalizat 0–1000"
        }
    }

    public static func recommended(forModelIdentifier modelIdentifier: String) -> CoordinateConvention {
        let lowercasedIdentifier = modelIdentifier.lowercased()
        if lowercasedIdentifier.hasPrefix("google/gemini") { return .normalizedTo1000 }
        if lowercasedIdentifier.contains("qwen3-vl") || lowercasedIdentifier.contains("qwen3.5-vl") { return .normalizedTo1000 }
        return .imagePixels
    }

    var toolCoordinateDescription: String {
        switch self {
        case .imagePixels:
            return "Coordinates are in pixels of that screenshot: x from the left edge, y from the top edge."
        case .normalizedTo1000:
            return "Coordinates are normalized to 0-1000 across that screenshot: x=0 is the left edge, x=1000 the right edge, y=0 the top edge, y=1000 the bottom edge."
        }
    }

    public func promptDescription(imageWidth: Int, imageHeight: Int) -> String {
        switch self {
        case .imagePixels:
            return "\(imageWidth)x\(imageHeight) pixels; point coordinates are pixels of this image (origin top-left)"
        case .normalizedTo1000:
            return "point coordinates are normalized 0-1000 on both axes (origin top-left, 1000 = right/bottom edge)"
        }
    }

    /// Converts a model coordinate to a pixel position in the screenshot, clamped to the image.
    public func imagePixelPoint(modelX: Double, modelY: Double, imagePixelSize: CGSize) -> CGPoint {
        let pixelX: Double
        let pixelY: Double
        switch self {
        case .imagePixels:
            pixelX = modelX
            pixelY = modelY
        case .normalizedTo1000:
            pixelX = modelX / 1000 * Double(imagePixelSize.width)
            pixelY = modelY / 1000 * Double(imagePixelSize.height)
        }
        return CGPoint(
            x: min(max(pixelX, 0), Double(imagePixelSize.width)),
            y: min(max(pixelY, 0), Double(imagePixelSize.height))
        )
    }

    /// The inverse: expresses a screenshot pixel in this convention (used to describe the user's drawings).
    public func modelPoint(fromImagePixel imagePixel: CGPoint, imagePixelSize: CGSize) -> CGPoint {
        switch self {
        case .imagePixels:
            return imagePixel
        case .normalizedTo1000:
            return CGPoint(
                x: Double(imagePixel.x) / Double(imagePixelSize.width) * 1000,
                y: Double(imagePixel.y) / Double(imagePixelSize.height) * 1000
            )
        }
    }
}
