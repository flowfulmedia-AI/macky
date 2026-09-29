import SwiftUI

/// Macky's own visual identity: mint to violet.
enum MackyDesign {
    static let accent = Color(red: 0.20, green: 0.84, blue: 0.70)
    static let accentSecondary = Color(red: 0.52, green: 0.42, blue: 0.98)

    static let accentGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardBackground = Color.primary.opacity(0.05)
    static let cornerRadius: CGFloat = 10
}

/// Shows the pointing-hand cursor on hover, so clickable things feel clickable.
struct PointingHandOnHover: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointingHandOnHover() -> some View {
        modifier(PointingHandOnHover())
    }
}
