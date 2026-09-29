import XCTest
@testable import MackyCore

final class PointingInstructionTests: XCTestCase {
    func testParsesToolArguments() {
        let instruction = PointingInstruction(toolArgumentsJSON: #"{"screen":2,"x":"640","y":400.5,"label":" Export "}"#)
        XCTAssertEqual(instruction, PointingInstruction(screenNumber: 2, x: 640, y: 400.5, label: "Export"))
    }

    func testToolArgumentsDefaultScreenAndRejectMissingCoordinates() {
        XCTAssertEqual(PointingInstruction(toolArgumentsJSON: #"{"x":1,"y":2}"#)?.screenNumber, 1)
        XCTAssertNil(PointingInstruction(toolArgumentsJSON: #"{"x":1}"#))
        XCTAssertNil(PointingInstruction(toolArgumentsJSON: "not json"))
    }

    func testParsesFallbackTagBodies() {
        XCTAssertEqual(PointingInstruction(fallbackTagBody: "point:1,640,400,Export"),
                       PointingInstruction(screenNumber: 1, x: 640, y: 400, label: "Export"))
        XCTAssertEqual(PointingInstruction(fallbackTagBody: "point: 640, 400, Save, as"),
                       PointingInstruction(screenNumber: 1, x: 640, y: 400, label: "Save, as"))
        XCTAssertEqual(PointingInstruction(fallbackTagBody: "point:2,10.5,20:Meniu File"),
                       PointingInstruction(screenNumber: 2, x: 10.5, y: 20, label: "Meniu File"))
        XCTAssertNil(PointingInstruction(fallbackTagBody: "point:abc"))
        XCTAssertNil(PointingInstruction(fallbackTagBody: "something else"))
    }
}

final class PointTagStreamFilterTests: XCTestCase {
    func testRemovesTagSplitAcrossChunks() {
        var filter = PointTagStreamFilter()
        var visibleText = ""
        var instructions: [PointingInstruction] = []
        for chunk in ["Apasă pe Export. [", "[poi", "nt:1,640,4", "00,Export]", "] Gata."] {
            let output = filter.consume(chunk)
            visibleText += output.visibleText
            instructions += output.pointingInstructions
        }
        visibleText += filter.flush()
        XCTAssertEqual(visibleText, "Apasă pe Export.  Gata.")
        XCTAssertEqual(instructions, [PointingInstruction(screenNumber: 1, x: 640, y: 400, label: "Export")])
    }

    func testKeepsNonPointBracketsAsText() {
        var filter = PointTagStreamFilter()
        let output = filter.consume("Vezi [[nota]] și [x].")
        XCTAssertEqual(output.visibleText + filter.flush(), "Vezi [[nota]] și [x].")
        XCTAssertTrue(output.pointingInstructions.isEmpty)
    }

    func testUnclosedTagIsEventuallyReleased() {
        var filter = PointTagStreamFilter()
        let output = filter.consume("Text [[neînchis")
        XCTAssertEqual(output.visibleText, "Text ")
        XCTAssertEqual(filter.flush(), "[[neînchis")
    }
}

final class CoordinateConventionTests: XCTestCase {
    func testRecommendedConventionPerModelFamily() {
        XCTAssertEqual(CoordinateConvention.recommended(forModelIdentifier: "google/gemini-2.5-flash"), .normalizedTo1000)
        XCTAssertEqual(CoordinateConvention.recommended(forModelIdentifier: "anthropic/claude-sonnet-4.5"), .imagePixels)
        XCTAssertEqual(CoordinateConvention.recommended(forModelIdentifier: "qwen/qwen3-vl-235b-a22b-instruct"), .normalizedTo1000)
    }

    func testConvertsNormalizedAndClamps() {
        let imageSize = CGSize(width: 1280, height: 800)
        XCTAssertEqual(CoordinateConvention.normalizedTo1000.imagePixelPoint(modelX: 500, modelY: 250, imagePixelSize: imageSize), CGPoint(x: 640, y: 200))
        XCTAssertEqual(CoordinateConvention.imagePixels.imagePixelPoint(modelX: 2000, modelY: -5, imagePixelSize: imageSize), CGPoint(x: 1280, y: 0))
    }
}

final class ScreenGeometryTests: XCTestCase {
    // Primary: 1512x982 Retina laptop at origin. Secondary: 2560x1440 monitor placed to the LEFT and higher,
    // so it has negative x and a y range extending above the primary screen.
    let primaryFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let secondaryFrame = CGRect(x: -2560, y: 200, width: 2560, height: 1440)

    func testCapturePixelSizeDownscalesRetinaAndNeverUpscales() {
        XCTAssertEqual(ScreenGeometry.capturePixelSize(screenPointSize: CGSize(width: 1512, height: 982), backingScaleFactor: 2, maximumLongEdge: 1280),
                       CGSize(width: 1280, height: 831))
        XCTAssertEqual(ScreenGeometry.capturePixelSize(screenPointSize: CGSize(width: 1024, height: 768), backingScaleFactor: 1, maximumLongEdge: 1280),
                       CGSize(width: 1024, height: 768))
    }

    func testImagePixelToAppKitOnPrimaryScreen() {
        let screen = CapturedScreenGeometry(screenNumber: 1, displayIdentifier: 1, frameInAppKitGlobalCoordinates: primaryFrame, imagePixelSize: CGSize(width: 1280, height: 831))
        let topLeft = ScreenGeometry.appKitGlobalPoint(fromImagePixel: .zero, on: screen)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 982, accuracy: 0.001)
        let center = ScreenGeometry.appKitGlobalPoint(fromImagePixel: CGPoint(x: 640, y: 415.5), on: screen)
        XCTAssertEqual(center.x, 756, accuracy: 0.001)
        XCTAssertEqual(center.y, 491, accuracy: 0.001)
    }

    func testImagePixelToAppKitOnSecondaryScreenWithNegativeOrigin() {
        let screen = CapturedScreenGeometry(screenNumber: 2, displayIdentifier: 2, frameInAppKitGlobalCoordinates: secondaryFrame, imagePixelSize: CGSize(width: 1280, height: 720))
        let point = ScreenGeometry.appKitGlobalPoint(fromImagePixel: CGPoint(x: 1280, y: 720), on: screen)
        XCTAssertEqual(point.x, 0, accuracy: 0.001)
        XCTAssertEqual(point.y, 200, accuracy: 0.001)
        let roundTrip = ScreenGeometry.imagePixel(fromAppKitGlobalPoint: CGPoint(x: -1280, y: 920), on: screen)
        XCTAssertEqual(roundTrip.x, 640, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, 360, accuracy: 0.001)
    }

    func testQuartzConversionRoundTrip() {
        let appKitPoint = CGPoint(x: -100, y: 1500)
        let quartzPoint = ScreenGeometry.quartzGlobalPoint(fromAppKitGlobalPoint: appKitPoint, primaryScreenHeight: 982)
        XCTAssertEqual(quartzPoint, CGPoint(x: -100, y: -518))
        XCTAssertEqual(ScreenGeometry.appKitGlobalPoint(fromQuartzGlobalPoint: quartzPoint, primaryScreenHeight: 982), appKitPoint)
        let quartzRect = CGRect(x: 10, y: 20, width: 100, height: 30)
        XCTAssertEqual(ScreenGeometry.appKitGlobalRect(fromQuartzGlobalRect: quartzRect, primaryScreenHeight: 982),
                       CGRect(x: 10, y: 932, width: 100, height: 30))
    }

    func testOverlayLocalConversion() {
        let local = ScreenGeometry.overlayLocalPoint(fromAppKitGlobalPoint: CGPoint(x: -2460, y: 1540), overlayFrameInAppKitGlobalCoordinates: secondaryFrame)
        XCTAssertEqual(local, CGPoint(x: 100, y: 100))
        let localRect = ScreenGeometry.overlayLocalRect(fromAppKitGlobalRect: CGRect(x: 10, y: 900, width: 50, height: 20), overlayFrameInAppKitGlobalCoordinates: primaryFrame)
        XCTAssertEqual(localRect, CGRect(x: 10, y: 62, width: 50, height: 20))
    }

    func testFlightArcStartsAndEndsAtEndpoints() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 400, y: 300)
        XCTAssertEqual(ScreenGeometry.pointOnFlightArc(from: start, to: end, progress: 0), start)
        XCTAssertEqual(ScreenGeometry.pointOnFlightArc(from: start, to: end, progress: 1), end)
        let middle = ScreenGeometry.pointOnFlightArc(from: start, to: end, progress: 0.5)
        XCTAssertNotEqual(middle, CGPoint(x: 200, y: 150), "the path should curve, not be a straight line")
        XCTAssertEqual(ScreenGeometry.easeInOut(0), 0)
        XCTAssertEqual(ScreenGeometry.easeInOut(1), 1)
        XCTAssertEqual(ScreenGeometry.easeInOut(0.5), 0.5, accuracy: 0.0001)
    }
}

final class AccessibilitySnapPolicyTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testSnapsToSmallNearbyButton() {
        XCTAssertTrue(AccessibilitySnapPolicy.shouldSnap(role: "AXButton", elementFrame: CGRect(x: 100, y: 100, width: 80, height: 24), screenFrame: screen, distanceFromTargetPoint: 10))
    }

    func testRejectsLargeContainersFarPointsAndUnknownRoles() {
        XCTAssertFalse(AccessibilitySnapPolicy.shouldSnap(role: "AXButton", elementFrame: CGRect(x: 0, y: 0, width: 900, height: 700), screenFrame: screen, distanceFromTargetPoint: 0))
        XCTAssertFalse(AccessibilitySnapPolicy.shouldSnap(role: "AXButton", elementFrame: CGRect(x: 100, y: 100, width: 20, height: 20), screenFrame: screen, distanceFromTargetPoint: 200))
        XCTAssertFalse(AccessibilitySnapPolicy.shouldSnap(role: "AXWebArea", elementFrame: CGRect(x: 100, y: 100, width: 20, height: 20), screenFrame: screen, distanceFromTargetPoint: 0))
    }
}
