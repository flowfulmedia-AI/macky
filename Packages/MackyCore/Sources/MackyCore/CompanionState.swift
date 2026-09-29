import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum CompanionState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
    case failed(message: String)

    public var displayName: String {
        switch self {
        case .idle: return "Gata"
        case .listening: return "Te ascult…"
        case .transcribing: return "Transcriu…"
        case .thinking: return "Mă gândesc…"
        case .speaking: return "Răspund"
        case .failed: return "Eroare"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }
}

/// Decides whether an Accessibility element found under a pointing target is a good thing
/// to snap the cursor and highlight to. Large containers (a whole web page, a canvas)
/// would make the highlight useless, so only compact, interactive elements qualify.
public enum AccessibilitySnapPolicy {
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXLink",
        "AXTab", "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXCell",
        "AXRow", "AXDockItem", "AXSegmentedControl", "AXImage", "AXStaticText"
    ]

    /// Roles that are usually a child of the real control (a label inside a button), so the parent is preferred.
    public static let rolesThatPreferParent: Set<String> = ["AXStaticText", "AXImage", "AXGroup", "AXUnknown"]

    public static func shouldSnap(role: String, elementFrame: CGRect, screenFrame: CGRect, distanceFromTargetPoint: Double) -> Bool {
        guard interactiveRoles.contains(role) else { return false }
        guard elementFrame.width >= 4, elementFrame.height >= 4 else { return false }
        let screenArea = Double(screenFrame.width * screenFrame.height)
        let elementArea = Double(elementFrame.width * elementFrame.height)
        guard screenArea > 0, elementArea / screenArea < 0.08 else { return false }
        // The element should be where the model pointed, not somewhere far away.
        let halfDiagonal = (Double(elementFrame.width * elementFrame.width + elementFrame.height * elementFrame.height)).squareRoot() / 2
        return distanceFromTargetPoint <= halfDiagonal + 4
    }
}
