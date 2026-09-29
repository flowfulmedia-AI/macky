import AppKit
import MackyCore
import SwiftUI

/// Where the notch is, in AppKit global coordinates. On Macs without a notch, a notch-sized
/// area in the middle of the menu bar plays the same role.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchRect: CGRect
    let hasHardwareNotch: Bool

    static func current() -> NotchGeometry? {
        let screenWithNotch = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = screenWithNotch ?? NSScreen.screens.first else { return nil }
        let screenFrame = screen.frame

        if screenWithNotch != nil,
           let unobscuredLeftArea = screen.auxiliaryTopLeftArea,
           let unobscuredRightArea = screen.auxiliaryTopRightArea {
            // The notch is what is left between the two unobscured corners of the menu bar.
            let notchHeight = screen.safeAreaInsets.top
            let notchWidth = screenFrame.width - unobscuredLeftArea.width - unobscuredRightArea.width
            let notchRect = CGRect(x: screenFrame.minX + unobscuredLeftArea.width, y: screenFrame.maxY - notchHeight,
                                   width: notchWidth, height: notchHeight)
            return NotchGeometry(screenFrame: screenFrame, notchRect: notchRect, hasHardwareNotch: true)
        }

        let menuBarHeight = max(screenFrame.maxY - screen.visibleFrame.maxY, 24)
        let virtualNotchWidth: CGFloat = 190
        let notchRect = CGRect(x: screenFrame.midX - virtualNotchWidth / 2, y: screenFrame.maxY - menuBarHeight,
                               width: virtualNotchWidth, height: menuBarHeight)
        return NotchGeometry(screenFrame: screenFrame, notchRect: notchRect, hasHardwareNotch: false)
    }
}

@MainActor
final class NotchPanelModel: ObservableObject {
    @Published var isExpanded = false
    @Published var notchSize: CGSize = CGSize(width: 190, height: 32)
}

/// A panel may normally not cover the menu bar; this one has to, to grow out of the notch.
private final class NotchPanel: KeyablePanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Macky's home in the notch: touching the notch with the mouse drops the panel down;
/// moving away folds it back. While Macky is busy, a small live indicator hugs the notch.
@MainActor
final class NotchPanelController {
    static let expandedContentSize = NSSize(width: 400, height: 560)
    /// Room left and right of the notch for the live indicator.
    private static let liveIndicatorExtraWidth: CGFloat = 96
    private static let hoverDelayBeforeExpanding: TimeInterval = 0.12
    private static let delayBeforeCollapsing: TimeInterval = 0.45

    private let model = NotchPanelModel()
    private let session: CompanionSession
    private let makeContent: @MainActor () -> AnyView

    private var panel: NotchPanel?
    private var notchGeometry: NotchGeometry?
    private var mouseTrackingTimer: Timer?
    private var screenChangeObserver: NSObjectProtocol?
    private var hoverStartDate: Date?
    private var leaveStartDate: Date?
    /// Opened by code (first run): stays open until the mouse has visited it and left.
    private var isPinnedOpen = false
    private var mouseHasEnteredSincePinning = false

    private(set) var isRunning = false

    init(session: CompanionSession, makeContent: @escaping @MainActor () -> AnyView) {
        self.session = session
        self.makeContent = makeContent
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildPanel()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackMouse()
            }
        }
        mouseTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanel() }
        }
    }

    func stop() {
        isRunning = false
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
        screenChangeObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func expand(pinned: Bool = false) {
        guard let panel else { return }
        isPinnedOpen = pinned
        mouseHasEnteredSincePinning = false
        leaveStartDate = nil
        panel.ignoresMouseEvents = false
        model.isExpanded = true
    }

    func collapse() {
        guard let panel else { return }
        isPinnedOpen = false
        model.isExpanded = false
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { panel.resignKey() }
        hoverStartDate = nil
        leaveStartDate = nil
    }

    // MARK: Private

    private func rebuildPanel() {
        panel?.orderOut(nil)
        guard let geometry = NotchGeometry.current() else { return }
        notchGeometry = geometry
        model.notchSize = geometry.notchRect.size

        let panelWidth = max(Self.expandedContentSize.width, geometry.notchRect.width + Self.liveIndicatorExtraWidth)
        let panelHeight = Self.expandedContentSize.height + geometry.notchRect.height
        let panelFrame = NSRect(
            x: geometry.notchRect.midX - panelWidth / 2,
            y: geometry.screenFrame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        let notchPanel = NotchPanel(contentRect: panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notchPanel.isFloatingPanel = true
        // Above the menu bar so it can merge with the notch.
        notchPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        notchPanel.backgroundColor = .clear
        notchPanel.isOpaque = false
        notchPanel.hasShadow = false
        notchPanel.hidesOnDeactivate = false
        notchPanel.isReleasedWhenClosed = false
        notchPanel.becomesKeyOnlyIfNeeded = true
        notchPanel.ignoresMouseEvents = !model.isExpanded
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        notchPanel.contentView = NSHostingView(rootView: NotchRootView(
            model: model,
            session: session,
            agentManager: session.backgroundAgentManager,
            panelSize: panelFrame.size,
            content: makeContent()
        ))
        notchPanel.setFrame(panelFrame, display: true)
        notchPanel.orderFrontRegardless()
        panel = notchPanel
    }

    private func trackMouse() {
        guard let notchGeometry, let panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let now = Date()

        if !model.isExpanded {
            // Touching the notch (or the very top edge right around it) opens the panel.
            let hotZone = notchGeometry.notchRect.insetBy(dx: -14, dy: 0)
            let isInHotZone = mouseLocation.x >= hotZone.minX && mouseLocation.x <= hotZone.maxX
                && mouseLocation.y >= hotZone.minY - 2 && mouseLocation.y <= notchGeometry.screenFrame.maxY + 1
            if isInHotZone {
                if let hoverStartDate {
                    if now.timeIntervalSince(hoverStartDate) >= Self.hoverDelayBeforeExpanding { expand() }
                } else {
                    hoverStartDate = now
                }
            } else {
                hoverStartDate = nil
            }
            return
        }

        let expandedArea = expandedContentFrame(in: panel.frame, notchGeometry: notchGeometry).insetBy(dx: -12, dy: -12)
        if expandedArea.contains(mouseLocation) {
            mouseHasEnteredSincePinning = true
            leaveStartDate = nil
            return
        }
        if isPinnedOpen && !mouseHasEnteredSincePinning { return }
        if let leaveStartDate {
            if now.timeIntervalSince(leaveStartDate) >= Self.delayBeforeCollapsing { collapse() }
        } else {
            leaveStartDate = now
        }
    }

    /// The visible, expanded part: centered under the notch, as wide as the content.
    private func expandedContentFrame(in panelFrame: CGRect, notchGeometry: NotchGeometry) -> CGRect {
        CGRect(
            x: panelFrame.midX - Self.expandedContentSize.width / 2,
            y: panelFrame.minY,
            width: Self.expandedContentSize.width,
            height: panelFrame.height
        )
    }
}

/// Draws either the dropped-down panel or, while Macky works, a small live indicator around the notch.
private struct NotchRootView: View {
    @ObservedObject var model: NotchPanelModel
    @ObservedObject var session: CompanionSession
    @ObservedObject var agentManager: BackgroundAgentManager
    let panelSize: CGSize
    let content: AnyView

    var body: some View {
        ZStack(alignment: .top) {
            if model.isExpanded {
                VStack(spacing: 0) {
                    // The notch itself sits here; the panel grows out from under it.
                    Color.clear.frame(height: model.notchSize.height)
                    content
                        .padding(.horizontal, 10)
                }
                .frame(width: NotchPanelController.expandedContentSize.width, height: panelSize.height)
                .background(NotchDropShape(topCornerRadius: 10, bottomCornerRadius: 26).fill(Color.black))
                .environment(\.colorScheme, .dark)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.3, anchor: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.3, anchor: .top).combined(with: .opacity)
                ))
            } else if session.state.isBusy || agentManager.runningJobCount > 0 {
                liveIndicator
                    .transition(.opacity)
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.isExpanded)
        .animation(.easeInOut(duration: 0.2), value: session.state.isBusy || agentManager.runningJobCount > 0)
    }

    /// A black band as tall as the notch and a bit wider, with Macky on the left and the activity on the right.
    private var liveIndicator: some View {
        HStack {
            MackyCursorShape()
                .fill(MackyDesign.accentGradient)
                .frame(width: 13, height: 13)
                .padding(.leading, 12)
            Spacer()
            liveActivityGlyph
                .padding(.trailing, 12)
        }
        .frame(width: model.notchSize.width + 96, height: model.notchSize.height)
        .background(NotchDropShape(topCornerRadius: 6, bottomCornerRadius: 12).fill(Color.black))
    }

    @ViewBuilder
    private var liveActivityGlyph: some View {
        switch session.state {
        case .listening:
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { barIndex in
                        Capsule()
                            .fill(MackyDesign.accent)
                            .frame(width: 2.5, height: 4 + 8 * CGFloat((sin(time * 8 + Double(barIndex)) + 1) / 2))
                    }
                }
            }
        case .transcribing, .thinking:
            ProgressView().controlSize(.mini).tint(MackyDesign.accent)
        case .speaking:
            Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundColor(MackyDesign.accent)
        default:
            if agentManager.runningJobCount > 0 {
                // A background agent is working.
                HStack(spacing: 3) {
                    ProgressView().controlSize(.mini).tint(MackyDesign.accentSecondary)
                    if agentManager.runningJobCount > 1 {
                        Text("\(agentManager.runningJobCount)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    }
                }
            } else {
                EmptyView()
            }
        }
    }
}

/// A shape that hangs from the top edge: small outward curves at the top (so it blends into the
/// menu bar like the real notch) and large rounded corners at the bottom.
struct NotchDropShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY
        let bottom = rect.maxY
        let left = rect.minX
        let right = rect.maxX

        path.move(to: CGPoint(x: left, y: top))
        path.addQuadCurve(to: CGPoint(x: left + topCornerRadius, y: top + topCornerRadius), control: CGPoint(x: left + topCornerRadius, y: top))
        path.addLine(to: CGPoint(x: left + topCornerRadius, y: bottom - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: left + topCornerRadius + bottomCornerRadius, y: bottom), control: CGPoint(x: left + topCornerRadius, y: bottom))
        path.addLine(to: CGPoint(x: right - topCornerRadius - bottomCornerRadius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right - topCornerRadius, y: bottom - bottomCornerRadius), control: CGPoint(x: right - topCornerRadius, y: bottom))
        path.addLine(to: CGPoint(x: right - topCornerRadius, y: top + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: right - topCornerRadius, y: top))
        path.closeSubpath()
        return path
    }
}
