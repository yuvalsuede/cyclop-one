import AppKit
import SwiftUI
import Combine

// MARK: - Eye View Model

/// Observable model for the EyeView, enabling property updates
/// without replacing the entire SwiftUI rootView hierarchy.
@MainActor
final class EyeViewModel: ObservableObject {
    @Published var status: DotStatus = .idle
    @Published var isRecording: Bool = false
}

// MARK: - Observable Eye View

/// Wrapper around EyeView that reads from an EyeViewModel environment object.
/// This allows FloatingDot to update status/recording via the view model
/// instead of replacing the hosting view's rootView.
private struct ObservableEyeView: View {
    @EnvironmentObject var viewModel: EyeViewModel

    var body: some View {
        EyeView(status: viewModel.status, isRecording: viewModel.isRecording)
    }
}

// MARK: - FloatingDot NSPanel

/// A 48px circular floating dot that acts as the primary UI for Cyclop One.
/// Stays on top of all windows. Click opens a popover, drag repositions,
/// right-click shows context menu.
/// A separate StatusLabelWindow floats above it showing what the agent is doing.
@MainActor
class FloatingDot: NSPanel, NSPopoverDelegate {

    // MARK: - Properties

    private let dotSize: CGFloat = 48
    private let panelSize: CGFloat = 64
    private var hostingView: NSHostingView<AnyView>!
    private let viewModel = EyeViewModel()
    private var statusCancellable: AnyCancellable?
    private var stepProgressCancellable: AnyCancellable?
    private var popover: NSPopover?
    private weak var coordinator: AgentCoordinator?

    /// Separate window for status label above the eye.
    private var statusLabel: StatusLabelWindow?

    /// Track drag state
    private var isDragging = false
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero

    // MARK: - Circular Hit Test View

    /// An NSView subclass that restricts hit-testing to the inscribed circle,
    /// ensuring clicks outside the dot's circular shape pass through.
    private class CircularHitTestView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2.0
            let dx = point.x - center.x
            let dy = point.y - center.y
            if dx * dx + dy * dy > radius * radius {
                return nil
            }
            return super.hitTest(point)
        }
    }

    // MARK: - Initialization

    init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        setupDotView()
        setupStatusLabel()
        positionOnScreen()
        subscribeToStateChanges(coordinator: coordinator)
        subscribeToRecordingState()
        configureAccessibility()
    }

    // MARK: - Panel Configuration

    private func configurePanel() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = true
    }

    // MARK: - Dot View

    private func setupDotView() {
        let eyeView = ObservableEyeView()
            .environmentObject(viewModel)

        hostingView = NSHostingView(rootView: AnyView(eyeView))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)

        // Use CircularHitTestView as contentView so clicks outside
        // the inscribed circle pass through to windows behind.
        let hitTestView = CircularHitTestView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        hitTestView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: hitTestView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: hitTestView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: hitTestView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: hitTestView.bottomAnchor),
        ])
        contentView = hitTestView
    }

    // MARK: - Status Label

    private func setupStatusLabel() {
        statusLabel = StatusLabelWindow()
        statusLabel?.orderFront(nil)
        statusLabel?.alphaValue = 0 // Start hidden
    }

    // MARK: - State Subscription

    private func subscribeToStateChanges(coordinator: AgentCoordinator) {
        statusCancellable = coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self = self else { return }
                let dotStatus = DotStatus.from(newState)
                self.viewModel.status = dotStatus
                self.updateStatusLabel(newState)
            }
        // Subscribe to step progress for richer status display
        stepProgressCancellable = coordinator.$stepProgressText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, let coord = self.coordinator else { return }
                if coord.state.isActive {
                    self.updateStatusLabel(coord.state)
                }
            }
    }

    private func updateStatusLabel(_ state: AgentState) {
        guard let label = statusLabel else { return }
        let dotStatus = DotStatus.from(state)

        if state.isActive {
            // Show step progress if available, otherwise fall back to state text
            let displayText: String
            if let coord = coordinator, !coord.stepProgressText.isEmpty {
                displayText = coord.stepProgressText
            } else {
                displayText = state.displayText
            }
            label.update(
                text: displayText,
                color: dotStatus.color,
                onCancel: { [weak self] in self?.coordinator?.cancel() }
            )
            // Keep ignoresMouseEvents = true so CGEvent clicks from the agent
            // pass through the label and don't accidentally hit the cancel button.
            // Users can cancel via the popover or Escape key instead.
            label.ignoresMouseEvents = true
            label.positionAbove(eyeFrame: self.frame)

            if label.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    label.animator().alphaValue = 1
                }
            }
        } else {
            // Fade out
            if label.alphaValue > 0 {
                // Brief delay so "Done" is visible
                let delay: TimeInterval = (state == .done || state == .idle) ? 1.5 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak label] in
                    guard let label = label else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.3
                        label.animator().alphaValue = 0
                    }
                    label.ignoresMouseEvents = true
                }
            }
        }
    }

    // MARK: - Recording State Subscription

    private func subscribeToRecordingState() {
        Task {
            await ScreenCaptureService.shared.setCaptureStateHandler { @MainActor [weak self] isCapturing in
                guard let self = self else { return }
                self.viewModel.isRecording = isCapturing
            }
        }
    }

    // MARK: - Screen Positioning

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 24

        let x = screenFrame.maxX - panelSize - margin
        let y = screenFrame.minY + margin

        setFrameOrigin(NSPoint(x: x, y: y))
        statusLabel?.positionAbove(eyeFrame: self.frame)
    }

    // MARK: - Mouse Events

    override var canBecomeKey: Bool { popover?.isShown == true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = frame.origin

        let myPID = ProcessInfo.processInfo.processIdentifier
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != myPID {
            coordinator?.previousFrontmostPID = frontApp.processIdentifier
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let currentMouseLocation = NSEvent.mouseLocation
        let dx = currentMouseLocation.x - dragStartMouseLocation.x
        let dy = currentMouseLocation.y - dragStartMouseLocation.y

        if abs(dx) > 3 || abs(dy) > 3 {
            isDragging = true
        }

        if isDragging {
            let newOrigin = NSPoint(
                x: dragStartWindowOrigin.x + dx,
                y: dragStartWindowOrigin.y + dy
            )
            setFrameOrigin(newOrigin)
            // Move status label with the eye
            statusLabel?.positionAbove(eyeFrame: self.frame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            togglePopover()
        }
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(at: event)
    }

    // MARK: - Accessibility

    private func configureAccessibility() {
        setAccessibilityRole(.button)
        setAccessibilityLabel("Cyclop One")
        setAccessibilityEnabled(true)
    }

    override func accessibilityPerformPress() -> Bool {
        togglePopover()
        return true
    }

    // MARK: - Popover

    func dismissPopover() {
        if let existing = popover, existing.isShown {
            existing.close()
        }
        popover = nil
    }

    func allWindowNumbers() -> [Int] {
        var numbers: [Int] = []
        if windowNumber > 0 {
            numbers.append(windowNumber)
        }
        if let pop = popover, pop.isShown,
           let popWindow = pop.contentViewController?.view.window,
           popWindow.windowNumber > 0 {
            numbers.append(popWindow.windowNumber)
        }
        if let labelNum = statusLabel?.windowNumber, labelNum > 0 {
            numbers.append(labelNum)
        }
        return numbers
    }

    func togglePopover() {
        if let existing = popover, existing.isShown {
            existing.close()
            popover = nil
            return
        }

        guard let coordinator = coordinator else { return }
        guard let contentView = contentView else { return }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self

        let popoverView = DotPopoverView(onDismiss: { [weak pop] in
            pop?.close()
        })
        .environmentObject(coordinator)

        pop.contentViewController = NSHostingController(rootView: popoverView)

        // Anchor popover to the actual eye circle (48px centered in 64px panel)
        let inset = (panelSize - dotSize) / 2
        let dotRect = NSRect(x: inset, y: inset, width: dotSize, height: dotSize)
        pop.show(
            relativeTo: dotRect,
            of: contentView,
            preferredEdge: .minX
        )

        NSApp.activate(ignoringOtherApps: true)

        popover = pop
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        // Make the popover window key synchronously, removing the asyncAfter hack.
        popover?.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Context Menu

    private func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Cyclop One",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        guard let cv = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: cv)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
