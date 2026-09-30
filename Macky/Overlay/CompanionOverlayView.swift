import MackyCore
import SwiftUI

/// Fills one screen. Draws Macky's cursor, its status accessory, the answer bubble and the
/// highlight around a pointed element, but only the parts that fall on this screen.
struct CompanionOverlayView: View {
    @ObservedObject var model: CompanionOverlayModel
    let screenFrame: CGRect

    private static let cursorSize: CGFloat = 26
    private static let bubbleMaximumWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let highlightRect = model.highlightRect, screenFrame.intersects(highlightRect) {
                highlightView(for: highlightRect)
            }
            if isCursorOnThisScreen {
                cursorGroup
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: model.isVisible)
        .allowsHitTesting(false)
    }

    private var isCursorOnThisScreen: Bool {
        screenFrame.insetBy(dx: -30, dy: -30).contains(model.cursorTipPosition)
    }

    private var cursorLocalPosition: CGPoint {
        ScreenGeometry.overlayLocalPoint(fromAppKitGlobalPoint: model.cursorTipPosition, overlayFrameInAppKitGlobalCoordinates: screenFrame)
    }

    @ViewBuilder
    private var cursorGroup: some View {
        let tip = cursorLocalPosition
        let size = Self.cursorSize

        MackyCursorShape()
            .fill(MackyDesign.accentGradient)
            .overlay(MackyCursorShape().stroke(Color.white.opacity(0.95), lineWidth: 1.5))
            .frame(width: size, height: size)
            .shadow(color: MackyDesign.accent.opacity(0.7), radius: model.activity == .pointing ? 10 : 5)
            .scaleEffect(model.activity == .pointing ? 1.15 : 1, anchor: .topLeading)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: model.activity)
            .position(x: tip.x + size / 2, y: tip.y + size / 2)

        activityAccessory
            .position(x: tip.x + size + 18, y: tip.y + size / 2 + 2)

        if let bubbleText = displayedBubbleText {
            let bubblePosition = bubbleTopLeading(forCursorTip: tip)
            Text(bubbleText)
                .font(MackyDesign.rounded(13.5, .medium))
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(7)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MackyDesign.primaryButtonGlow.opacity(0.55), lineWidth: 1))
                        .shadow(color: MackyDesign.primaryButtonGlow.opacity(0.35), radius: 12)
                )
                .frame(maxWidth: Self.bubbleMaximumWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .offset(x: bubblePosition.x, y: bubblePosition.y)
        }
    }

    /// While pointing, the bubble shows the element's name; otherwise the answer text.
    private var displayedBubbleText: String? {
        if model.activity == .pointing, let pointingLabel = model.pointingLabel {
            return pointingLabel
        }
        return model.bubbleText
    }

    /// Places the bubble below-right of the cursor, flipping left/up near screen edges.
    private func bubbleTopLeading(forCursorTip tip: CGPoint) -> CGPoint {
        var x = tip.x + 30
        var y = tip.y + 34
        if x + Self.bubbleMaximumWidth > screenFrame.width - 8 {
            x = tip.x - Self.bubbleMaximumWidth - 10
        }
        if y + 140 > screenFrame.height {
            y = tip.y - 150
        }
        return CGPoint(x: max(8, x), y: max(8, y))
    }

    @ViewBuilder
    private var activityAccessory: some View {
        switch model.activity {
        case .listening, .dictating:
            AudioLevelBarsView(audioLevel: model.audioLevel, tint: model.activity == .dictating ? MackyDesign.accentSecondary : MackyDesign.accent)
        case .thinking:
            ThinkingDotsView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 14, weight: .bold))
        case .speaking, .pointing:
            EmptyView()
        }
    }

    private func highlightView(for highlightRect: CGRect) -> some View {
        let localRect = ScreenGeometry.overlayLocalRect(fromAppKitGlobalRect: highlightRect, overlayFrameInAppKitGlobalCoordinates: screenFrame)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(MackyDesign.accentGradient, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MackyDesign.accent.opacity(0.12)))
            .shadow(color: MackyDesign.accent.opacity(0.8), radius: 8)
            .frame(width: localRect.width + 10, height: localRect.height + 10)
            .position(x: localRect.midX, y: localRect.midY)
            .transition(.opacity)
    }
}

/// Macky's pointer: a rounded arrow whose tip is the view's top-left corner.
struct MackyCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: width * 0.02, y: height * 0.86))
        path.addQuadCurve(to: CGPoint(x: width * 0.2, y: height * 0.9), control: CGPoint(x: width * 0.06, y: height * 0.98))
        path.addLine(to: CGPoint(x: width * 0.42, y: height * 0.62))
        path.addLine(to: CGPoint(x: width * 0.82, y: height * 0.6))
        path.addQuadCurve(to: CGPoint(x: width * 0.86, y: height * 0.44), control: CGPoint(x: width * 0.98, y: height * 0.56))
        path.closeSubpath()
        return path
    }
}

struct AudioLevelBarsView: View {
    let audioLevel: Float
    let tint: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { barIndex in
                    let wobble = (sin(time * 9 + Double(barIndex) * 1.3) + 1) / 2
                    let height = 4 + CGFloat(audioLevel) * 16 * CGFloat(0.45 + 0.55 * wobble)
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 22)
            .padding(.horizontal, 6)
            .background(Capsule().fill(Color.black.opacity(0.7)))
        }
    }
}

struct ThinkingDotsView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    let pulse = (sin(time * 6 - Double(dotIndex) * 0.9) + 1) / 2
                    Circle()
                        .fill(MackyDesign.accent)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * pulse)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.7)))
        }
    }
}
