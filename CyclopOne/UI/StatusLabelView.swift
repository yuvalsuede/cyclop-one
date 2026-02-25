import AppKit
import SwiftUI

// MARK: - Status Label Window

/// A separate floating window that shows the current agent status above the eye.
/// Appears when the agent is active, hides when idle.
@MainActor
class StatusLabelWindow: NSPanel {

    private var hostingView: NSHostingView<StatusLabelView>!
    private let labelWidth: CGFloat = 200
    private let labelHeight: CGFloat = 44

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true

        let view = StatusLabelView(text: "", color: .blue, onCancel: {})
        hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: labelWidth, height: labelHeight)
        contentView = hostingView
    }

    func update(text: String, color: Color, onCancel: @escaping () -> Void) {
        hostingView.rootView = StatusLabelView(text: text, color: color, onCancel: onCancel)
    }

    /// Position this label above the given eye panel frame.
    func positionAbove(eyeFrame: NSRect) {
        let x = eyeFrame.midX - labelWidth / 2
        let y = eyeFrame.maxY + 4
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// SwiftUI view for the floating status label.
/// Note: Cancel button removed because CGEvent clicks from the agent can
/// accidentally trigger it, aborting runs. Users cancel via Escape key or popover.
struct StatusLabelView: View {
    let text: String
    let color: Color
    let onCancel: () -> Void

    var body: some View {
        if !text.isEmpty {
            HStack(spacing: 6) {
                // Animated status dot
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)

                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.black.opacity(0.8))
                    .shadow(color: color.opacity(0.3), radius: 6)
            )
            .frame(maxWidth: 200)
            .allowsHitTesting(false)
        }
    }
}
