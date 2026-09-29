import AppKit
import SwiftUI

/// Asks "Macky wants to click X. OK?" in a small card next to the target, before any action
/// changes something on the computer. Unanswered cards count as "no" after a timeout.
@MainActor
final class ActionConfirmationController {
    private static let cardSize = NSSize(width: 300, height: 118)
    private static let answerTimeoutInSeconds: UInt64 = 30

    private var confirmationPanel: KeyablePanel?
    private var pendingContinuation: CheckedContinuation<Bool, Never>?
    private var currentConfirmationIdentifier: UUID?

    /// `nearPoint` is in AppKit global coordinates; nil places the card near the mouse.
    func requestConfirmation(actionDescription: String, stepNumber: Int, nearPoint: CGPoint?) async -> Bool {
        cancelPendingConfirmation()
        let anchorPoint = nearPoint ?? NSEvent.mouseLocation

        let confirmationIdentifier = UUID()
        currentConfirmationIdentifier = confirmationIdentifier
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            showCard(actionDescription: actionDescription, stepNumber: stepNumber, anchorPoint: anchorPoint)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.answerTimeoutInSeconds * 1_000_000_000)
                // Only time out this card, never a newer one.
                guard let self, self.currentConfirmationIdentifier == confirmationIdentifier else { return }
                self.finish(with: false)
            }
        }
    }

    /// Used when the user interrupts Macky: an open question is answered "no".
    func cancelPendingConfirmation() {
        finish(with: false)
    }

    private func finish(with isApproved: Bool) {
        confirmationPanel?.orderOut(nil)
        confirmationPanel = nil
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(returning: isApproved)
    }

    private func showCard(actionDescription: String, stepNumber: Int, anchorPoint: CGPoint) {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.cardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the overlay cursor, which lives at the status bar level.
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: ActionConfirmationCard(
            actionDescription: actionDescription,
            stepNumber: stepNumber,
            onApprove: { [weak self] in self?.finish(with: true) },
            onDecline: { [weak self] in self?.finish(with: false) }
        ))

        let screenFrame = NSScreen.screens.first { NSMouseInRect(anchorPoint, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchorPoint.x + 24, y: anchorPoint.y - Self.cardSize.height - 24)
        if origin.x + Self.cardSize.width > screenFrame.maxX { origin.x = anchorPoint.x - Self.cardSize.width - 24 }
        if origin.y < screenFrame.minY { origin.y = anchorPoint.y + 24 }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - Self.cardSize.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - Self.cardSize.height - 8)
        panel.setFrame(NSRect(origin: origin, size: Self.cardSize), display: true)

        // Key so that Enter / Esc answer the card; non-activating, so the user's app stays in front.
        panel.makeKeyAndOrderFront(nil)
        confirmationPanel = panel
    }
}

private struct ActionConfirmationCard: View {
    let actionDescription: String
    let stepNumber: Int
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                MackyCursorShape()
                    .fill(MackyDesign.accentGradient)
                    .frame(width: 14, height: 14)
                Text(stepNumber > 1 ? "Macky vrea să continue (pasul \(stepNumber)):" : "Macky vrea să:")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Text(actionDescription)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            HStack {
                Button("Nu", action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Da, fă-o", action: onApprove)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 300, height: 118, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MackyDesign.accent.opacity(0.6), lineWidth: 1))
        )
        .environment(\.colorScheme, .dark)
    }
}
