import SwiftUI

/// Macky's visual identity: a soft dark interface, pastel cards, glowing pill buttons and a friendly mascot.
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

    // Dark surfaces.
    static let windowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let sidebarBackground = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let surface = Color.white.opacity(0.06)
    static let surfaceStrong = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.09)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)

    // Pastel cards, as in sticky notes.
    static let butter = Color(red: 1.00, green: 0.95, blue: 0.80)
    static let periwinkle = Color(red: 0.86, green: 0.89, blue: 1.00)
    static let blush = Color(red: 1.00, green: 0.84, blue: 0.89)
    static let mint = Color(red: 0.84, green: 0.96, blue: 0.89)
    static let pastels = [butter, periwinkle, blush, mint]

    // The glowing primary button.
    static let primaryButtonGradient = LinearGradient(
        colors: [Color(red: 0.78, green: 0.86, blue: 1.00), Color(red: 0.56, green: 0.68, blue: 1.00)],
        startPoint: .top, endPoint: .bottom
    )
    static let primaryButtonGlow = Color(red: 0.36, green: 0.42, blue: 1.00)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Buttons

/// The big glowing pill, like "Ține ⌃⌥ ca să vorbești".
struct MackyPrimaryPillStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MackyDesign.rounded(15, .semibold))
            .foregroundColor(Color(red: 0.08, green: 0.10, blue: 0.25))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(MackyDesign.primaryButtonGradient)
                    .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1).blur(radius: 0.5).padding(1))
                    .overlay(Capsule().stroke(MackyDesign.primaryButtonGlow.opacity(0.9), lineWidth: 1.5))
            )
            .shadow(color: MackyDesign.primaryButtonGlow.opacity(isActive || configuration.isPressed ? 0.9 : 0.45), radius: isActive ? 16 : 9)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Quiet dark pill with a hairline border.
struct MackySecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MackyDesign.rounded(13, .medium))
            .foregroundColor(MackyDesign.textPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(configuration.isPressed ? MackyDesign.surfaceStrong : MackyDesign.surface))
            .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Round icon button for toolbars.
struct MackyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(MackyDesign.textSecondary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(configuration.isPressed ? MackyDesign.surfaceStrong : MackyDesign.surface))
            .contentShape(Circle())
    }
}

// MARK: - Cards

extension View {
    /// A dark translucent card with a hairline border.
    func mackyCard(cornerRadius: CGFloat = 18, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MackyDesign.surface)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
            )
    }
}

/// A slightly tilted pastel card with an arrow, for suggestions.
struct SuggestionCardView: View {
    let text: String
    let symbol: String
    let color: Color
    let tilt: Double
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.45))
                Text(text)
                    .font(MackyDesign.rounded(13, .semibold))
                    .foregroundColor(.black.opacity(0.82))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.12, green: 0.14, blue: 0.40))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(MackyDesign.primaryButtonGradient))
                        .overlay(Circle().stroke(MackyDesign.primaryButtonGlow.opacity(0.8), lineWidth: 1))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
                    .shadow(color: .black.opacity(0.35), radius: isHovering ? 10 : 5, y: 3)
            )
            .rotationEffect(.degrees(isHovering ? 0 : tilt))
            .scaleEffect(isHovering ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointingHandOnHover()
    }
}

// MARK: - Mascot

enum MackyMood: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case happy
    case error
}

/// Macky's mascot: a soft cloud with ^ ^ eyes. It breathes, blinks, bounces while listening,
/// looks up while thinking and talks while speaking.
struct MackyMascotView: View {
    var mood: MackyMood = .idle
    var size: CGFloat = 64
    var colors: [Color] = [Color(red: 0.62, green: 0.93, blue: 0.80), Color(red: 0.72, green: 0.66, blue: 1.00)]
    var audioLevel: Float = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breathing = 1 + 0.025 * sin(time * 2)
            let bounce: CGFloat = mood == .listening ? CGFloat(4 * abs(sin(time * 6))) * CGFloat(0.4 + min(Double(audioLevel), 1)) : 0
            ZStack {
                if mood == .listening {
                    Circle()
                        .stroke(colors[0].opacity(0.5), lineWidth: 2)
                        .scaleEffect(1 + 0.25 * CGFloat((time * 1.2).truncatingRemainder(dividingBy: 1)))
                        .opacity(1 - (time * 1.2).truncatingRemainder(dividingBy: 1))
                        .frame(width: size, height: size)
                }
                cloudBody
                    .shadow(color: colors[0].opacity(0.55), radius: size * 0.18)
                face(time: time)
            }
            .frame(width: size, height: size)
            .scaleEffect(x: breathing, y: 2 - breathing)
            .offset(y: -bounce)
        }
        .frame(width: size, height: size)
    }

    private var cloudBody: some View {
        let gradient = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack {
            Circle().frame(width: size * 0.62, height: size * 0.62).offset(x: -size * 0.14, y: -size * 0.06)
            Circle().frame(width: size * 0.56, height: size * 0.56).offset(x: size * 0.16, y: -size * 0.10)
            Circle().frame(width: size * 0.40, height: size * 0.40).offset(x: size * 0.30, y: size * 0.10)
            Circle().frame(width: size * 0.42, height: size * 0.42).offset(x: -size * 0.30, y: size * 0.12)
            Capsule().frame(width: size * 0.84, height: size * 0.42).offset(y: size * 0.14)
        }
        .foregroundStyle(gradient)
        .overlay(
            // Soft highlight on top.
            Ellipse()
                .fill(Color.white.opacity(0.35))
                .frame(width: size * 0.34, height: size * 0.14)
                .offset(x: -size * 0.12, y: -size * 0.26)
                .blur(radius: size * 0.03)
        )
    }

    @ViewBuilder
    private func face(time: Double) -> some View {
        let eyeSpacing = size * 0.22
        let eyeWidth = size * 0.17
        let eyeY = mood == .thinking ? -size * 0.02 : size * 0.04
        // Blink for a moment every few seconds.
        let isBlinking = (time.truncatingRemainder(dividingBy: 4.2)) < 0.12 && mood != .happy
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                eye(isBlinking: isBlinking, width: eyeWidth)
                    .offset(x: CGFloat(side) * eyeSpacing / 1.1 + (mood == .thinking ? size * 0.03 : 0), y: eyeY)
            }
            if mood == .speaking {
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: size * 0.11, height: size * (0.04 + 0.06 * abs(sin(time * 11))))
                    .offset(y: size * 0.17)
            }
            if mood == .thinking {
                HStack(spacing: size * 0.04) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.white)
                            .frame(width: size * 0.05, height: size * 0.05)
                            .opacity(0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.8)))
                    }
                }
                .offset(y: size * 0.18)
            }
        }
    }

    @ViewBuilder
    private func eye(isBlinking: Bool, width: CGFloat) -> some View {
        switch mood {
        case .listening:
            Capsule()
                .fill(Color.white)
                .frame(width: width * 0.42, height: isBlinking ? width * 0.1 : width * 0.62)
        case .error:
            Image(systemName: "xmark")
                .font(.system(size: width * 0.6, weight: .heavy))
                .foregroundColor(.white)
        default:
            // The happy ^ arc.
            EyeArc()
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(2, width * 0.24), lineCap: .round))
                .frame(width: width, height: isBlinking ? width * 0.08 : width * 0.45)
        }
    }
}

private struct EyeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.9))
        return path
    }
}

/// Mascot colors per section, so each part of Macky has its own little character.
enum MascotPalette {
    static let mint = [Color(red: 0.62, green: 0.93, blue: 0.80), Color(red: 0.72, green: 0.66, blue: 1.00)]
    static let peach = [Color(red: 1.00, green: 0.80, blue: 0.62), Color(red: 1.00, green: 0.62, blue: 0.62)]
    static let sky = [Color(red: 0.66, green: 0.82, blue: 1.00), Color(red: 0.50, green: 0.60, blue: 1.00)]
    static let lemon = [Color(red: 1.00, green: 0.92, blue: 0.62), Color(red: 1.00, green: 0.75, blue: 0.45)]
    static let lilac = [Color(red: 0.86, green: 0.76, blue: 1.00), Color(red: 1.00, green: 0.70, blue: 0.86)]
    static let silver = [Color(red: 0.86, green: 0.88, blue: 0.94), Color(red: 0.68, green: 0.72, blue: 0.84)]
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
