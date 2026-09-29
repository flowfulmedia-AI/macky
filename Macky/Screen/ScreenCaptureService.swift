import AppKit
import MackyCore
import ScreenCaptureKit

struct CapturedScreen {
    let geometry: CapturedScreenGeometry
    let jpegData: Data
    let displayName: String
    let containsMouseCursor: Bool

    var promptDescription: ScreenshotDescription {
        ScreenshotDescription(
            screenNumber: geometry.screenNumber,
            displayName: displayName,
            imagePixelSize: geometry.imagePixelSize,
            containsMouseCursor: containsMouseCursor
        )
    }
}

enum ScreenCaptureError: LocalizedError {
    case permissionMissing
    case noDisplayFound
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionMissing: return "Macky nu are permisiunea Screen Recording."
        case .noDisplayFound: return "Nu găsesc niciun ecran de capturat."
        case .imageEncodingFailed: return "Nu am putut comprima captura de ecran."
        }
    }
}

/// Takes one screenshot per screen, only when the user asks something. Macky's own windows
/// (panel, overlay cursor) and apps the user excluded (password managers etc.) are left out.
@MainActor
final class ScreenCaptureService {
    func captureScreens(
        includeAllScreens: Bool,
        maximumLongEdge: Int,
        excludedBundleIdentifiers: Set<String>,
        alwaysIncludedWindowNumbers: [Int] = []
    ) async throws -> [CapturedScreen] {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permissionMissing }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouseLocation = NSEvent.mouseLocation
        let allScreens = NSScreen.screens
        guard let screenWithMouse = allScreens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? allScreens.first else {
            throw ScreenCaptureError.noDisplayFound
        }
        // Screenshot 1 is always the screen the user is looking at (the one with the mouse).
        var screensToCapture = [screenWithMouse]
        if includeAllScreens {
            screensToCapture += allScreens.filter { $0 != screenWithMouse }
        }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let excludedApplications = shareableContent.applications.filter { application in
            application.processID == ownProcessIdentifier || excludedBundleIdentifiers.contains(application.bundleIdentifier)
        }
        // Windows listed here are captured even though their app is excluded (used by calibration).
        let exceptedWindows = shareableContent.windows.filter { alwaysIncludedWindowNumbers.contains(Int($0.windowID)) }

        var capturedScreens: [CapturedScreen] = []
        for screen in screensToCapture {
            guard let displayIdentifier = screen.displayIdentifier,
                  let display = shareableContent.displays.first(where: { $0.displayID == displayIdentifier }) else { continue }

            let capturePixelSize = ScreenGeometry.capturePixelSize(
                screenPointSize: screen.frame.size,
                backingScaleFactor: Double(screen.backingScaleFactor),
                maximumLongEdge: Double(maximumLongEdge)
            )
            let contentFilter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: exceptedWindows)
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = Int(capturePixelSize.width)
            streamConfiguration.height = Int(capturePixelSize.height)
            // The system cursor in the screenshot tells the model where the user is looking.
            streamConfiguration.showsCursor = true

            let capturedImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: streamConfiguration)
            guard let jpegData = Self.jpegData(from: capturedImage) else { throw ScreenCaptureError.imageEncodingFailed }

            let geometry = CapturedScreenGeometry(
                screenNumber: capturedScreens.count + 1,
                displayIdentifier: displayIdentifier,
                frameInAppKitGlobalCoordinates: screen.frame,
                imagePixelSize: CGSize(width: capturedImage.width, height: capturedImage.height)
            )
            capturedScreens.append(CapturedScreen(
                geometry: geometry,
                jpegData: jpegData,
                displayName: screen.localizedName,
                containsMouseCursor: screen == screenWithMouse
            ))
        }

        guard !capturedScreens.isEmpty else { throw ScreenCaptureError.noDisplayFound }
        return capturedScreens
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}

extension NSScreen {
    var displayIdentifier: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Height of the primary screen (the one with the menu bar), needed to flip between AppKit and Quartz coordinates.
    static var primaryScreenHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }
}
